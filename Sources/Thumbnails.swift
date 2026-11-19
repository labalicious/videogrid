import AppKit
import QuickLookThumbnailing

/// Picture-of-the-video thumbnails for the file browser.
/// Quick Look handles what macOS can decode (MP4, MOV, M4V…); everything else (MKV, AVI, WebM…)
/// gets a frame grabbed by libVLC. Grabbed frames are cached on disk so they appear instantly next time.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private let memory = NSCache<NSURL, NSImage>()
    private var waiting: [URL: [(NSImage?) -> Void]] = [:]
    private var failed: Set<URL> = []
    private let vlcQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("local.videogrid/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    nonisolated static let pixelWidth = 480

    private init() { memory.countLimit = 400 }

    /// Already-made thumbnail, if any.
    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    /// Calls `done` on the main thread with the thumbnail, or nil if none could be made.
    func thumbnail(for url: URL, done: @escaping (NSImage?) -> Void) {
        if let img = cached(url) { done(img); return }
        if failed.contains(url) { done(nil); return }
        if waiting[url] != nil { waiting[url]!.append(done); return }
        waiting[url] = [done]

        let disk = diskURL(for: url)
        if let disk, let img = NSImage(contentsOf: disk) { finish(url, img); return }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: Self.pixelWidth / 2, height: Self.pixelWidth / 2),
            scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let cg = rep?.cgImage
            Task { @MainActor in
                if let cg {
                    self.finish(url, NSImage(cgImage: cg, size: .zero))
                } else if MediaFiles.isAudio(url) {
                    self.finish(url, nil)
                } else {
                    self.grabWithVLC(url, saveTo: disk)
                }
            }
        }
    }

    private func grabWithVLC(_ url: URL, saveTo disk: URL?) {
        Player.backgroundWork.enter()
        vlcQueue.addOperation {
            defer { Player.backgroundWork.leave() }
            let cg = FrameGrabber.grab(url, maxWidth: Self.pixelWidth)
            if let cg, let disk {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: disk)
            }
            Task { @MainActor in self.finish(url, cg.map { NSImage(cgImage: $0, size: .zero) }) }
        }
    }

    private func finish(_ url: URL, _ img: NSImage?) {
        if let img { memory.setObject(img, forKey: url as NSURL) } else { failed.insert(url) }
        for cb in waiting.removeValue(forKey: url) ?? [] { cb(img) }
    }

    /// Forget everything about these files (e.g. after Refresh), so changed files get new pictures.
    func forgetFailures() { failed.removeAll() }

    /// One cache file per path + size + modification date, so an edited file gets a new picture.
    private func diskURL(for url: URL) -> URL? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let key = "\(url.path)|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        var h: UInt64 = 0xcbf29ce484222325          // FNV-1a
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return diskDir.appendingPathComponent(String(h, radix: 16) + ".jpg")
    }
}

/// Grabs one frame from a video with libVLC, rendering into memory (no window).
/// Blocking: call it off the main thread.
enum FrameGrabber {
    private final class Context {
        let maxWidth: Int
        var width = 0, height = 0
        var buffer: UnsafeMutableRawPointer?
        var frames = 0
        let ready = DispatchSemaphore(value: 0)
        init(maxWidth: Int) { self.maxWidth = maxWidth }
        deinit { buffer?.deallocate() }
    }

    static func grab(_ url: URL, maxWidth: Int, timeout: TimeInterval = 8) -> CGImage? {
        guard let vlc = VLC.shared.instance, let media = libvlc_media_new_path(vlc, url.path) else { return nil }
        defer { libvlc_media_release(media) }

        // Find the length so the picture comes from 10% in, past black openings and titles.
        libvlc_media_parse_with_options(media, libvlc_media_parse_local, 3000)
        let parseDeadline = Date().addingTimeInterval(3.5)
        while libvlc_media_get_parsed_status(media) == libvlc_media_parsed_status_t(rawValue: 0), Date() < parseDeadline {
            usleep(20_000)
        }
        let length = libvlc_media_get_duration(media)
        for opt in [":no-audio", ":no-spu", ":no-osd", ":avcodec-threads=1", ":input-fast-seek"] {
            libvlc_media_add_option(media, opt)
        }
        if length > 4000 { libvlc_media_add_option(media, ":start-time=\(Double(length) / 10_000)") }

        guard let mp = libvlc_media_player_new_from_media(media) else { return nil }
        let ctx = Context(maxWidth: maxWidth)
        let opaque = Unmanaged.passRetained(ctx).toOpaque()
        defer {
            libvlc_media_player_stop(mp)
            libvlc_media_player_release(mp)
            Unmanaged<Context>.fromOpaque(opaque).release()
        }

        libvlc_video_set_callbacks(mp, { opaque, planes in
            planes?.pointee = Unmanaged<Context>.fromOpaque(opaque!).takeUnretainedValue().buffer
            return nil
        }, nil, { opaque, _ in
            let c = Unmanaged<Context>.fromOpaque(opaque!).takeUnretainedValue()
            c.frames += 1
            if c.frames == 3 { c.ready.signal() }   // skip the first frames, which can be grey
        }, opaque)

        libvlc_video_set_format_callbacks(mp, { opaque, chroma, width, height, pitches, lines in
            guard let opaque, let ptr = opaque.pointee, let chroma, let width, let height, let pitches, let lines
            else { return 0 }
            let c = Unmanaged<Context>.fromOpaque(ptr).takeUnretainedValue()
            let srcW = Int(width.pointee), srcH = Int(height.pointee)
            guard srcW > 0, srcH > 0 else { return 0 }
            let w = min(srcW, c.maxWidth) & ~1
            let h = max(2, (srcH * w / srcW) & ~1)
            _ = "RV32".withCString { memcpy(chroma, $0, 4) }
            width.pointee = UInt32(w); height.pointee = UInt32(h)
            pitches.pointee = UInt32(w * 4); lines.pointee = UInt32(h)
            c.buffer?.deallocate()
            c.buffer = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
            c.width = w; c.height = h
            return 1
        }, nil)

        guard libvlc_media_player_play(mp) == 0, ctx.ready.wait(timeout: .now() + timeout) == .success else { return nil }
        libvlc_media_player_stop(mp)            // nothing writes to the buffer after this
        guard let buf = ctx.buffer, ctx.width > 0 else { return nil }
        let bytes = ctx.width * ctx.height * 4
        let data = Data(bytes: buf, count: bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        // VLC's RV32 is B, G, R, X in memory.
        return CGImage(width: ctx.width, height: ctx.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: ctx.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
