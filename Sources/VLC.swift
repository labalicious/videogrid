import AppKit

/// Owns the single libVLC instance that every tile's player shares.
final class VLC {
    static let shared = VLC()

    let instance: OpaquePointer?
    let version: String

    private init() {
        // Use the libVLC copy bundled inside the app (Contents/MacOS/plugins),
        // so updating or removing VLC.app can't break Video Grid.
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let plugins = exeDir.appendingPathComponent("plugins").path
            if FileManager.default.fileExists(atPath: plugins) {
                setenv("VLC_PLUGIN_PATH", plugins, 1)
            }
        }

        let preferred = [
            "--no-video-title-show",          // no filename splash over the video
            "--no-snapshot-preview",
            "--no-stats",
            "--mouse-hide-timeout=86400000",  // don't hide the cursor over tiles
        ]
        var args = preferred
        #if VLCGRID_DEBUG
        if let extra = ProcessInfo.processInfo.environment["VLCGRID_VLCARGS"] {
            args += extra.split(separator: " ").map(String.init)
        }
        #endif
        instance = VLC.makeInstance(args) ?? VLC.makeInstance([])
        version = String(cString: libvlc_get_version())
    }

    private static func makeInstance(_ args: [String]) -> OpaquePointer? {
        let cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)!) }
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return cargs.withUnsafeBufferPointer { libvlc_new(Int32($0.count), $0.baseAddress) }
    }
}
