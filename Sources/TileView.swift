import AppKit

protocol TileViewDelegate: AnyObject {
    func tileRequestsMaximizeToggle(_ tile: TileView)
    func tileRequestsSoloAudio(_ tile: TileView)
    func tileRequestsAddFiles(_ tile: TileView)
}

/// Small translucent label drawn over the video (tile number, file name, zoom, loop).
final class BadgeView: NSView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the video
}

/// Big "screen number" shown over every tile while a Play on Screen menu is open.
final class ScreenNumberView: NSView {
    private let label = NSTextField(labelWithString: "")
    var number = 0 { didSet { label.stringValue = "\(number)" } }
    var highlighted = false { didSet { updateColors() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        label.font = .systemFont(ofSize: 64, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 120),
            heightAnchor.constraint(equalToConstant: 110),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateColors() {
        layer?.backgroundColor = (highlighted ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.6)).cgColor
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(highlighted ? 0.9 : 0.35).cgColor
    }
}

/// One player in the grid: video (or playlist) on top, VLC-style controls along the bottom.
final class TileView: NSView {
    var number: Int {
        didSet { playlistView.tileNumber = number; playlistView.reload(); screenNumber.number = number }
    }
    let player = Player()
    weak var delegate: TileViewDelegate?

    let videoView = VideoView()
    private lazy var playlistView = PlaylistView(player: player, tileNumber: number)
    private let badge = BadgeView()
    private let selectionOverlay = SelectionOverlay()
    private let screenNumber = ScreenNumberView()
    private let bar = NSVisualEffectView()

    private var playButton: NSButton!
    private var repeatButton: NSButton!
    private var shuffleButton: NSButton!
    private var abButton: NSButton!
    private var muteButton: NSButton!
    private var playlistButton: NSButton!
    private let seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 125, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private var seekHoldUntil = Date.distantPast
    private var abPopover: NSPopover?
    private var symbols: [ObjectIdentifier: String] = [:]
    private var toggleSignature = ""

    static var showTitles = UserDefaults.standard.object(forKey: "showTitles") as? Bool ?? true

    var isSelected = false { didSet { updateBorder() } }
    /// Shows the tile's number large in the middle (while choosing a screen to send a video to).
    var showsScreenNumber = false { didSet { screenNumber.isHidden = !showsScreenNumber } }
    var screenNumberHighlighted = false {
        didSet { screenNumber.highlighted = screenNumberHighlighted; updateBorder() }
    }
    /// Tiles open showing their playlist, like VLC's main window.
    var showsPlaylist = true { didSet { applyMode() } }
    private var dropHighlight = false { didSet { updateBorder() } }

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        buildUI()

        videoView.player = player
        player.attach(videoView)
        player.onPlaylistChanged = { [weak self] in self?.playlistView.reload() }
        player.onItemChanged = { [weak self] in self?.videoView.resetZoom() }
        player.onStartedPlaying = { [weak self] in self?.videoView.reapplyCrop() }
        videoView.onMouseDown = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        videoView.onSelectionChanged = { [weak self] rect in self?.selectionOverlay.selection = rect }
        videoView.onDoubleClickUnzoomed = { [weak self] in
            guard let self else { return }
            self.delegate?.tileRequestsMaximizeToggle(self)
        }
        playlistView.onPlayRequested = { [weak self] in self?.showsPlaylist = false }
        playlistView.onAddRequested = { [weak self] in
            guard let self else { return }
            self.delegate?.tileRequestsAddFiles(self)
        }

        registerForDraggedTypes([.fileURL])
        applyMode()
        updateBorder()
        playlistView.reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: UI

    private func buildUI() {
        selectionOverlay.isHidden = true
        screenNumber.isHidden = true
        screenNumber.number = number
        for v in [videoView, selectionOverlay, playlistView, badge, bar, screenNumber] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active

        playButton = iconButton("play.fill", "Play / Pause (Space)", #selector(togglePlay))
        let prev = iconButton("backward.end.fill", "Previous (P)", #selector(previousItem))
        let next = iconButton("forward.end.fill", "Next (N)", #selector(nextItem))
        repeatButton = iconButton("repeat", "Repeat: off → all → one (L)", #selector(cycleRepeat))
        shuffleButton = iconButton("shuffle", "Random (R)", #selector(toggleShuffle))
        muteButton = iconButton("speaker.wave.2.fill", "Mute (M). ⌥-click to hear only this tile.", #selector(muteClicked))
        playlistButton = iconButton("list.bullet", "Playlist ↔ video (⌘L)", #selector(togglePlaylist))

        abButton = NSButton(title: "A-B", target: self, action: #selector(showABLoop))
        abButton.isBordered = false
        abButton.font = .systemFont(ofSize: 11, weight: .semibold)
        abButton.toolTip = "A→B loop. Keys: A sets start, B sets end, X clears."
        abButton.setContentHuggingPriority(.required, for: .horizontal)

        seekSlider.target = self
        seekSlider.action = #selector(seekChanged(_:))
        seekSlider.isContinuous = true
        seekSlider.controlSize = .small
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        seekSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        seekSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.controlSize = .small
        volumeSlider.toolTip = "Volume (↑/↓)"
        volumeSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [playButton, prev, next, timeLabel, seekSlider,
                                        repeatButton, shuffleButton, abButton, muteButton,
                                        volumeSlider, playlistButton])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        // On narrow tiles the least important controls drop out first.
        let drop: [(NSView, Float)] = [(volumeSlider, 500), (prev, 550), (next, 550), (shuffleButton, 600),
                                        (repeatButton, 610), (abButton, 620), (timeLabel, 650)]
        for (view, priority) in drop {
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: priority), for: view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),

            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            selectionOverlay.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: videoView.topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: videoView.bottomAnchor),

            playlistView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playlistView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playlistView.topAnchor.constraint(equalTo: topAnchor),
            playlistView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),

            screenNumber.centerXAnchor.constraint(equalTo: centerXAnchor),
            screenNumber.centerYAnchor.constraint(equalTo: videoView.centerYAnchor),
        ])
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        symbols[ObjectIdentifier(b)] = symbol
        return b
    }

    private func setSymbol(_ button: NSButton, _ symbol: String) {
        guard symbols[ObjectIdentifier(button)] != symbol else { return }
        symbols[ObjectIdentifier(button)] = symbol
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func applyMode() {
        playlistView.isHidden = !showsPlaylist
        videoView.isHidden = showsPlaylist
        playlistButton?.contentTintColor = showsPlaylist ? .controlAccentColor : nil
        refreshBadge()
    }

    private func updateBorder() {
        let green = dropHighlight || screenNumberHighlighted
        layer?.borderWidth = (isSelected || green) ? (screenNumberHighlighted ? 4 : 2) : 0
        layer?.borderColor = (green ? NSColor.systemGreen : NSColor.controlAccentColor).cgColor
    }

    // MARK: Timer

    func tick() {
        player.tick()
        videoView.applyPendingCrop()

        setSymbol(playButton, player.isPlaying ? "pause.fill" : "play.fill")
        let text = "\(TimeFormat.string(ms: player.time)) / \(TimeFormat.string(ms: player.length))"
        if timeLabel.stringValue != text { timeLabel.stringValue = text }
        let canSeek = player.length > 0 && player.hasActiveMedia
        if seekSlider.isEnabled != canSeek { seekSlider.isEnabled = canSeek }
        if Date() > seekHoldUntil {
            let pos = Double(player.position)
            if abs(seekSlider.doubleValue - pos) > 0.0005 { seekSlider.doubleValue = pos }
        }
        refreshToggles()
        refreshBadge()
    }

    private func refreshToggles() {
        let signature = "\(player.repeatMode.rawValue)|\(player.shuffle)|\(player.muted)|\(player.volume)|\(player.loopA != nil)|\(player.loopActive)"
        guard signature != toggleSignature else { return }
        toggleSignature = signature
        setSymbol(repeatButton, player.repeatMode == .one ? "repeat.1" : "repeat")
        repeatButton.contentTintColor = player.repeatMode == .off ? nil : .controlAccentColor
        shuffleButton.contentTintColor = player.shuffle ? .controlAccentColor : nil
        setSymbol(muteButton, player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        muteButton.contentTintColor = player.muted ? .systemOrange : nil
        if volumeSlider.integerValue != player.volume { volumeSlider.integerValue = player.volume }
        abButton.contentTintColor = player.loopActive ? .controlAccentColor
            : (player.loopA != nil ? .systemYellow : nil)
    }

    private func refreshBadge() {
        var parts: [String] = []
        if Self.showTitles {
            parts.append("\(number)")
            if let url = player.currentURL { parts.append(url.lastPathComponent) }
        }
        if player.lastError { parts.append("⚠︎ can't play this file") }
        if videoView.zoom > 1.001 { parts.append(String(format: "%.1f×", videoView.zoom)) }
        if player.loopActive, let a = player.loopA, let b = player.loopB {
            parts.append("A→B \(TimeFormat.string(ms: a))–\(TimeFormat.string(ms: b))")
        }
        let text = parts.joined(separator: "  ·  ")
        if badge.label.stringValue != text { badge.label.stringValue = text }
        let hidden = showsPlaylist || text.isEmpty
        if badge.isHidden != hidden { badge.isHidden = hidden }
    }

    // MARK: Actions

    @objc func togglePlay() {
        if player.togglePlayPause() { showsPlaylist = false }
    }

    func startPlayback() {
        if player.play() { showsPlaylist = false }
    }

    func restartPlayback() {
        if player.restart() { showsPlaylist = false }
    }

    @objc private func previousItem() { player.previous() }
    @objc private func nextItem() { player.next() }

    @objc private func cycleRepeat() {
        player.repeatMode = player.repeatMode.next
        refreshToggles()
    }

    @objc private func toggleShuffle() {
        player.shuffle.toggle()
        refreshToggles()
    }

    @objc private func seekChanged(_ sender: NSSlider) {
        seekHoldUntil = Date().addingTimeInterval(0.4)
        player.seek(toPosition: Float(sender.doubleValue))
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        player.volume = sender.integerValue
        if player.muted && player.volume > 0 { player.muted = false }
        refreshToggles()
    }

    private func adjustVolume(_ delta: Int) {
        player.volume = min(125, max(0, player.volume + delta))
        if player.muted { player.muted = false }
        refreshToggles()
    }

    func setMuted(_ muted: Bool) {
        player.muted = muted
        refreshToggles()
    }

    @objc private func muteClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            delegate?.tileRequestsSoloAudio(self)
        } else {
            setMuted(!player.muted)
        }
    }

    @objc func togglePlaylist() { showsPlaylist.toggle() }

    @objc private func showABLoop() {
        if let p = abPopover, p.isShown { p.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ABLoopViewController(player: player)
        popover.show(relativeTo: abButton.bounds, of: abButton, preferredEdge: .maxY)
        abPopover = popover
    }

    func add(_ urls: [URL], autoplay: Bool) {
        guard !urls.isEmpty else { return }
        let first = player.items.count
        player.append(urls)
        if autoplay && !player.isPlaying {
            player.play(index: first)
            showsPlaylist = false
        }
    }

    /// Adds the files and starts the first of them now, even if something else is playing.
    func playNow(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let first = player.items.count
        player.append(urls)
        player.play(index: first)
        showsPlaylist = false
    }

    /// Name of what this tile is playing (or has queued first), for menus.
    var currentTitle: String? {
        (player.currentURL ?? player.items.first)?.lastPathComponent
    }

    func shutdown() {
        abPopover?.close()
        player.shutdown(keepAlive: videoView)
    }

    // MARK: Keyboard (acts on the selected tile)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlay(); return true                                   // space
        case 123: player.seek(by: shift ? -1000 : -5000); return true        // ←
        case 124: player.seek(by: shift ? 1000 : 5000); return true          // →
        case 126: adjustVolume(5); return true                               // ↑
        case 125: adjustVolume(-5); return true                              // ↓
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "m": setMuted(!player.muted)
        case "n": player.next()
        case "p": player.previous()
        case "s": player.stop()
        case "l": cycleRepeat()
        case "r": toggleShuffle()
        case "a": player.markA(); refreshToggles()
        case "b": player.markB(); refreshToggles()
        case "x": player.clearLoop(); refreshToggles()
        case ".", "e": player.nextFrame()
        case "0": videoView.resetZoom()
        case "=", "+": videoView.zoom(by: 1.25)
        case "-": videoView.zoom(by: 0.8)
        case "f": delegate?.tileRequestsMaximizeToggle(self)
        default: return false
        }
        return true
    }

    // MARK: Drag & drop onto the video area: add and play

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !MediaFiles.urls(from: sender.draggingPasteboard).isEmpty else { return [] }
        dropHighlight = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let files = MediaFiles.expand(MediaFiles.urls(from: sender.draggingPasteboard))
        guard !files.isEmpty else { return false }
        add(files, autoplay: true)
        return true
    }
}
