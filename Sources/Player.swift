import AppKit

enum RepeatMode: Int {
    case off, all, one
    var next: RepeatMode { RepeatMode(rawValue: (rawValue + 1) % 3) ?? .off }
}

/// One libVLC media player plus a VLC-style playlist (repeat one/all, random, A→B loop).
///
/// Threading: calls that can block inside libVLC (set_media, stop, release) run on a
/// private serial queue. VLC's macOS video output waits on the main thread while it
/// creates its view, so blocking the main thread in those calls could deadlock. While
/// such a call is in flight (`isBusy`), the main thread doesn't touch the player at all.
final class Player {
    /// Every background libVLC call; the app waits on this before quitting.
    static let backgroundWork = DispatchGroup()

    private let mp: OpaquePointer
    private let queue = DispatchQueue(label: "videogrid.player")
    private var pendingOps = 0
    private var loadsPending = 0
    private(set) var released = false

    // Playlist
    private(set) var items: [URL] = []
    private(set) var currentIndex: Int?
    var repeatMode: RepeatMode = .off
    var shuffle = false { didSet { if shuffle != oldValue { rebuildShuffle(avoidFirst: nil) } } }
    private var shuffleOrder: [Int] = []

    // A→B loop (milliseconds)
    private(set) var loopA: Int64?
    private(set) var loopB: Int64?
    private var lastLoopJump = Date.distantPast

    // Audio
    var volume = 100 { didSet { applyAudio() } }
    var muted = false { didSet { applyAudio() } }

    // Cached status, refreshed by tick()
    private(set) var state = libvlc_NothingSpecial
    private(set) var time: Int64 = 0
    private(set) var length: Int64 = 0
    private(set) var position: Float = 0
    private(set) var lastError = false
    /// Source pixel size, sample aspect ratio, and whether the picture is rotated 90°.
    private(set) var geometry: (size: CGSize, sar: CGFloat, transposed: Bool)?
    private var pendingSeek: Int64?
    private var endHandled = true
    private var hadVideoOutput = false

    var onPlaylistChanged: (() -> Void)?
    var onItemChanged: (() -> Void)?
    var onStartedPlaying: (() -> Void)?
    /// VLC has (re)created its video output. VLC reuses the output between files, and a reused
    /// output keeps the old crop, so the zoom has to be sent again at this point.
    var onVideoOutput: (() -> Void)?

    /// The speakers libVLC was last told to use ("0": whatever macOS is using).
    private var speakers = "0"
    private var speakersObserver: NSObjectProtocol?

    init() {
        mp = libvlc_media_player_new(VLC.shared.instance)!
        applySpeakers()
        speakersObserver = NotificationCenter.default.addObserver(forName: Speakers.changed, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.applySpeakers() }
        }
    }

    /// Settings → Playback → Play sound through. libVLC moves the sound over right away,
    /// even mid-video, and keeps that device for the files after it.
    private func applySpeakers() {
        let device = Speakers.vlcDevice
        guard !released, device != speakers else { return }
        speakers = device
        background { mp in libvlc_audio_output_device_set(mp, nil, device) }
    }

    // MARK: Status

    var isBusy: Bool { pendingOps > 0 }
    var isPlaying: Bool {
        loadsPending > 0 || state == libvlc_Playing || state == libvlc_Opening || state == libvlc_Buffering
    }
    var isPaused: Bool { loadsPending == 0 && state == libvlc_Paused }
    var hasActiveMedia: Bool { loadsPending == 0 && (state == libvlc_Playing || state == libvlc_Paused) }
    var currentURL: URL? { currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    var loopActive: Bool {
        if let a = loopA, let b = loopB { return b > a }
        return false
    }

    func attach(_ view: NSView) {
        libvlc_media_player_set_nsobject(mp, Unmanaged.passUnretained(view).toOpaque())
    }

    /// Called ~30×/s by the window's timer.
    func tick() {
        guard !released, !isBusy else { return }
        let st = libvlc_media_player_get_state(mp)
        time = max(0, libvlc_media_player_get_time(mp))
        length = max(0, libvlc_media_player_get_length(mp))
        position = max(0, libvlc_media_player_get_position(mp))

        if st != state {
            state = st
            if st == libvlc_Playing { didStartPlaying() }
        }
        let hasVideoOutput = libvlc_media_player_has_vout(mp) > 0
        if hasVideoOutput != hadVideoOutput {
            hadVideoOutput = hasVideoOutput
            if hasVideoOutput { onVideoOutput?() }
        }
        if geometry == nil, st == libvlc_Playing || st == libvlc_Paused {
            geometry = probeGeometry()
        }
        if (st == libvlc_Ended || st == libvlc_Error) && !endHandled {
            endHandled = true
            if st == libvlc_Error { lastError = true } else { handleEnd() }
        }
        if loopActive, st == libvlc_Playing, let a = loopA, let b = loopB, time >= b,
           Date().timeIntervalSince(lastLoopJump) > 0.25 {
            lastLoopJump = Date()
            libvlc_media_player_set_time(mp, a)
            time = a
        }
    }

    private func didStartPlaying() {
        applyAudio()
        if let s = pendingSeek {
            pendingSeek = nil
            libvlc_media_player_set_time(mp, s)
        }
        onStartedPlaying?()
    }

    private func applyAudio() {
        guard !released, !isBusy else { return }   // re-applied when playback starts
        libvlc_audio_set_volume(mp, Int32(volume))
        libvlc_audio_set_mute(mp, muted ? 1 : 0)
    }

    // MARK: Transport

    func play(index: Int) {
        guard !released, items.indices.contains(index) else { return }
        let changed = index != currentIndex
        currentIndex = index
        if changed {
            loopA = nil; loopB = nil; pendingSeek = nil; geometry = nil
        }
        lastError = false
        endHandled = false
        hadVideoOutput = false
        time = 0; position = 0
        loadsPending += 1
        let path = items[index].path
        let instance = VLC.shared.instance
        background({ mp in
            guard let media = libvlc_media_new_path(instance, path) else { return }
            if changed { libvlc_video_set_crop_geometry(mp, "") }   // a new file starts unzoomed
            libvlc_media_player_set_media(mp, media)
            libvlc_media_release(media)
            libvlc_media_player_play(mp)
        }, completion: { [weak self] in
            self?.loadsPending -= 1
        })
        if changed { onItemChanged?() }
        onPlaylistChanged?()
    }

    /// Returns true if this started playback from an idle player.
    @discardableResult
    func togglePlayPause() -> Bool {
        guard !released, !isBusy else { return false }
        if state == libvlc_Playing || state == libvlc_Opening || state == libvlc_Buffering {
            libvlc_media_player_set_pause(mp, 1)
            return false
        }
        if state == libvlc_Paused {
            libvlc_media_player_set_pause(mp, 0)
            return false
        }
        return playFromIdle()
    }

    /// Play (or resume). Returns true if this started playback from an idle player.
    @discardableResult
    func play() -> Bool {
        guard !released, !isBusy else { return false }
        if state == libvlc_Paused { libvlc_media_player_set_pause(mp, 0); return false }
        if isPlaying { return false }
        return playFromIdle()
    }

    func pause() {
        guard !released, !isBusy, isPlaying else { return }
        libvlc_media_player_set_pause(mp, 1)
    }

    func stop() {
        guard !released else { return }
        endHandled = true
        background({ libvlc_media_player_stop($0) })
    }

    /// Jump back to the start (or to A when a loop is set) and play.
    @discardableResult
    func restart() -> Bool {
        guard !released, !isBusy else { return false }
        if hasActiveMedia {
            libvlc_media_player_set_time(mp, loopActive ? loopA! : 0)
            libvlc_media_player_set_pause(mp, 0)
            return false
        }
        return playFromIdle()
    }

    @discardableResult
    private func playFromIdle() -> Bool {
        if let c = currentIndex, items.indices.contains(c) { play(index: c); return true }
        if let first = playOrder.first { play(index: first); return true }
        return false
    }

    func seek(toPosition p: Float) {
        guard !released, !isBusy, hasActiveMedia else { return }
        libvlc_media_player_set_position(mp, min(max(p, 0), 1))
        position = p
    }

    func seek(toTime t: Int64) {
        guard !released, !isBusy, hasActiveMedia else { return }
        let clamped = max(0, length > 0 ? min(t, length) : t)
        libvlc_media_player_set_time(mp, clamped)
        time = clamped
    }

    func seek(by delta: Int64) { seek(toTime: time + delta) }

    func nextFrame() {
        guard !released, !isBusy, hasActiveMedia else { return }
        libvlc_media_player_next_frame(mp)
    }

    private var playOrder: [Int] {
        if shuffle && shuffleOrder.count == items.count { return shuffleOrder }
        return Array(items.indices)
    }

    func next(auto: Bool = false) {
        let order = playOrder
        guard !order.isEmpty else { return }
        guard let cur = currentIndex, let pos = order.firstIndex(of: cur) else {
            play(index: order[0]); return
        }
        if pos + 1 < order.count { play(index: order[pos + 1]); return }
        guard repeatMode == .all else { return }      // end of playlist
        if shuffle { rebuildShuffle(avoidFirst: cur) }
        play(index: playOrder[0])
    }

    func previous() {
        if hasActiveMedia && time > 3000 { seek(toTime: 0); return }
        let order = playOrder
        guard !order.isEmpty else { return }
        guard let cur = currentIndex, let pos = order.firstIndex(of: cur) else {
            play(index: order[0]); return
        }
        if pos > 0 { play(index: order[pos - 1]) }
        else if repeatMode == .all { play(index: order[order.count - 1]) }
        else { seek(toTime: 0) }
    }

    private func handleEnd() {
        guard let cur = currentIndex else { return }
        if loopActive, let a = loopA {           // file ended before B: go round again
            pendingSeek = a
            play(index: cur)
            return
        }
        switch repeatMode {
        case .one: play(index: cur)
        case .all, .off: next(auto: true)
        }
    }

    // MARK: A→B loop

    func setLoop(a: Int64?, b: Int64?) { loopA = a; loopB = b }

    func markA() {
        guard hasActiveMedia else { NSSound.beep(); return }
        loopA = time
        if let b = loopB, b <= time { loopB = nil }
    }

    func markB() {
        guard hasActiveMedia else { NSSound.beep(); return }
        let a = loopA ?? 0
        guard time > a else { NSSound.beep(); return }
        loopA = a
        loopB = time
        seek(toTime: a)
    }

    func clearLoop() { loopA = nil; loopB = nil }

    // MARK: Saving and restoring

    /// Where to pick up again: the playing position, or the one waiting to be applied.
    var resumeTime: Int64 { hasActiveMedia ? time : (pendingSeek ?? 0) }

    /// Puts back a saved playlist without starting it. Playing it later starts at `time`.
    func restore(items: [URL], current: Int?, time: Int64) {
        guard !released else { return }
        self.items = items
        currentIndex = current.flatMap { items.indices.contains($0) ? $0 : nil }
        pendingSeek = currentIndex != nil && time > 0 ? time : nil
        playlistMutated()
    }

    // MARK: Playlist editing

    func append(_ urls: [URL]) { insert(urls, at: items.count) }

    func insert(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty else { return }
        let i = min(max(0, index), items.count)
        items.insert(contentsOf: urls, at: i)
        if let c = currentIndex, c >= i { currentIndex = c + urls.count }
        playlistMutated()
    }

    func remove(at rows: IndexSet) {
        let rows = rows.filteredIndexSet { items.indices.contains($0) }
        guard !rows.isEmpty else { return }
        if let c = currentIndex {
            if rows.contains(c) { stop(); currentIndex = nil }
            else { currentIndex = c - rows.count(in: 0..<c) }
        }
        for i in rows.reversed() { items.remove(at: i) }
        playlistMutated()
    }

    func move(_ rows: IndexSet, to destination: Int) {
        let moving = rows.filter { items.indices.contains($0) }
        guard !moving.isEmpty else { return }
        var order = Array(items.indices)
        let insertAt = destination - moving.filter { $0 < destination }.count
        order.removeAll { rows.contains($0) }
        order.insert(contentsOf: moving, at: min(max(0, insertAt), order.count))
        let old = items
        items = order.map { old[$0] }
        if let c = currentIndex { currentIndex = order.firstIndex(of: c) }
        playlistMutated()
    }

    func clear() {
        stop()
        items = []
        currentIndex = nil
        playlistMutated()
    }

    private func playlistMutated() {
        if shuffle { rebuildShuffle(avoidFirst: nil) }
        onPlaylistChanged?()
    }

    private func rebuildShuffle(avoidFirst: Int?) {
        var order = Array(items.indices).shuffled()
        if let avoid = avoidFirst {
            if order.count > 1, order[0] == avoid { order.swapAt(0, 1) }
        } else if let c = currentIndex, let i = order.firstIndex(of: c) {
            order.swapAt(0, i)   // keep the current item first so the rest follows it
        }
        shuffleOrder = order
    }

    // MARK: Zoom support

    /// Applies a crop rectangle in source pixels (nil = whole picture).
    /// Returns false when the player is busy, so the caller can retry on the next tick.
    func setCrop(_ rect: CGRect?) -> Bool {
        guard !released else { return true }
        guard !isBusy else { return false }
        if let r = rect, let g = geometry {
            // Use VLC's "left+top+right+bottom" border form. libVLC 3.0.x misreads the
            // "WxH+X+Y" form (it takes W/H as the right/bottom edge), which skews any
            // crop that doesn't start at the top-left corner.
            let srcW = Int(g.transposed ? g.size.height : g.size.width)
            let srcH = Int(g.transposed ? g.size.width : g.size.height)
            let left = Int(r.minX), top = Int(r.minY)
            let right = max(0, srcW - Int(r.maxX)), bottom = max(0, srcH - Int(r.maxY))
            let geometry = "\(left)+\(top)+\(right)+\(bottom)"
            #if VLCGRID_DEBUG
            print("DEBUG crop \(Int(r.width))x\(Int(r.height)) at \(left),\(top) -> \(geometry)")
            #endif
            libvlc_video_set_crop_geometry(mp, geometry)
        } else {
            libvlc_video_set_crop_geometry(mp, "")
        }
        return true
    }

    #if VLCGRID_DEBUG
    func debugSetCrop(_ s: String) { print("DEBUG raw crop '\(s)'"); libvlc_video_set_crop_geometry(mp, s) }
    #endif

    private func probeGeometry() -> (size: CGSize, sar: CGFloat, transposed: Bool)? {
        guard let media = libvlc_media_player_get_media(mp) else { return nil }
        defer { libvlc_media_release(media) }
        var tracks: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_track_t>?>?
        let count = libvlc_media_tracks_get(media, &tracks)
        guard count > 0, let tracks else { return nil }
        defer { libvlc_media_tracks_release(tracks, count) }
        for i in 0..<Int(count) {
            guard let track = tracks[i], track.pointee.i_type == libvlc_track_video,
                  let v = track.pointee.video else { continue }
            let w = CGFloat(v.pointee.i_width), h = CGFloat(v.pointee.i_height)
            guard w > 0, h > 0 else { continue }
            let sar = (v.pointee.i_sar_num > 0 && v.pointee.i_sar_den > 0)
                ? CGFloat(v.pointee.i_sar_num) / CGFloat(v.pointee.i_sar_den) : 1
            let o = v.pointee.i_orientation
            let transposed = o == libvlc_video_orient_left_top || o == libvlc_video_orient_left_bottom
                || o == libvlc_video_orient_right_top || o == libvlc_video_orient_right_bottom
            return (CGSize(width: w, height: h), sar, transposed)
        }
        return nil
    }

    #if VLCGRID_DEBUG
    var debugDevice: String {
        guard let p = libvlc_audio_output_device_get(mp) else { return "none" }
        defer { free(p) }
        return String(cString: p)
    }
    #endif

    // MARK: Lifetime

    /// Stops and frees the player off the main thread. `keepAlive` (the video view)
    /// stays alive until libVLC has let go of it, then is released on the main thread.
    func shutdown(keepAlive: AnyObject) {
        guard !released else { return }
        released = true
        onPlaylistChanged = nil; onItemChanged = nil; onStartedPlaying = nil; onVideoOutput = nil
        if let o = speakersObserver { NotificationCenter.default.removeObserver(o); speakersObserver = nil }
        let token = Unmanaged.passRetained(keepAlive)
        background({ mp in
            libvlc_media_player_stop(mp)
            libvlc_media_player_set_nsobject(mp, nil)
            libvlc_media_player_release(mp)
        }, completion: { token.release() })
    }

    private func background(_ work: @escaping (OpaquePointer) -> Void, completion: (() -> Void)? = nil) {
        pendingOps += 1
        Player.backgroundWork.enter()
        let mp = self.mp
        queue.async {
            work(mp)
            Player.backgroundWork.leave()   // not on main: quitting waits on this from the main thread
            DispatchQueue.main.async {
                self.pendingOps -= 1
                completion?()
            }
        }
    }
}
