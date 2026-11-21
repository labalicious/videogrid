import AppKit
import NetFS

// MARK: - Saved session (Settings → Windows → "Resume where I left off")

struct SavedTile: Codable {
    var items: [String]
    var current: Int?
    var time: Int64
    var playing: Bool
    var repeatMode: Int
    var shuffle: Bool
    var volume: Int
    var muted: Bool
    var showsPlaylist: Bool
}

struct SavedWindow: Codable {
    var layout: String
    var frame: String
    var tiles: [SavedTile]
}

struct SavedSession: Codable {
    var windows: [SavedWindow]

    private static let key = "session"

    static func load() -> SavedSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

// MARK: - The file browser's starting folder

/// Finds the folder a new file browser opens in. If the chosen folder is on a server that isn't
/// connected or a drive that's unplugged, the browser opens the home folder instead, and
/// Video Grid quietly tries to reconnect the server (using passwords saved in the keychain).
enum StartFolder {
    /// Posted when the starting folder's server has been reconnected.
    static let reconnected = Notification.Name("VideoGridStartFolderReconnected")

    private static let serverKey = "browserRootServer"     // smb://… address of the folder's server
    private static let volumeKey = "browserRootVolume"     // where that server was mounted, e.g. /Volumes/Media
    private static var tried = false

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Remembers which server (if any) holds the folder, so it can be reconnected later.
    static func remember(_ url: URL) {
        let d = UserDefaults.standard
        let v = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeURLKey, .volumeIsLocalKey])
        if v?.volumeIsLocal == false, let server = v?.volumeURLForRemounting, let volume = v?.volume {
            d.set(server.absoluteString, forKey: serverKey)
            d.set(volume.path, forKey: volumeKey)
        } else {
            d.removeObject(forKey: serverKey)
            d.removeObject(forKey: volumeKey)
        }
    }

    /// Where to open now, and whether that's the home-folder stand-in.
    static func resolve() -> (url: URL, isFallback: Bool) {
        let wanted = Prefs.browserFolder
        if isAvailable(wanted) { return (wanted, false) }
        if let moved = onRemountedVolume(), isAvailable(moved) { return (moved, false) }
        return (home, true)
    }

    /// The folder is there now. Checks the volume list first, so a disconnected server
    /// never makes us wait on the network.
    static func isAvailable(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents      // ["/", "Volumes", "Media", …]
        if parts.count >= 3, parts[1] == "Volumes" {
            let volume = "/Volumes/" + parts[2]
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            guard mounted.contains(where: { $0.standardizedFileURL.path == volume }) else { return false }
        }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The same server can come back under another name (/Volumes/Media-1). Finds the folder there.
    private static func onRemountedVolume() -> URL? {
        let d = UserDefaults.standard
        guard let server = d.string(forKey: serverKey), let oldVolume = d.string(forKey: volumeKey) else { return nil }
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            guard (try? volume.resourceValues(forKeys: Set(keys)))?.volumeURLForRemounting?.absoluteString == server
            else { continue }
            return moved(Prefs.browserFolder, from: oldVolume, to: volume.path)
        }
        return nil
    }

    private static func moved(_ url: URL, from oldVolume: String, to newVolume: String) -> URL? {
        let path = url.standardizedFileURL.path
        guard path == oldVolume || path.hasPrefix(oldVolume + "/") else { return nil }
        return URL(fileURLWithPath: newVolume + path.dropFirst(oldVolume.count), isDirectory: true)
    }

    /// Called once at launch. If the starting folder's server isn't connected, try to connect it
    /// without asking for anything; on success, open browsers that fell back to home switch over.
    static func reconnectIfNeeded() {
        guard !tried else { return }
        tried = true
        let d = UserDefaults.standard
        // Reachable now: note its server, so it can be reconnected on a later launch.
        if isAvailable(Prefs.browserFolder) { remember(Prefs.browserFolder); return }
        guard onRemountedVolume() == nil,
              let serverString = d.string(forKey: serverKey), let server = URL(string: serverString),
              let oldVolume = d.string(forKey: volumeKey) else { return }
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI          // no password or error dialogs at launch
        var request: AsyncRequestID?
        NetFSMountURLAsync(server as CFURL, nil, nil, nil, open, nil, &request, .main) { status, _, mountpoints in
            guard status == 0 else { return }
            let mounted = (mountpoints as? [String])?.first ?? oldVolume
            let target = moved(Prefs.browserFolder, from: oldVolume, to: mounted) ?? Prefs.browserFolder
            guard isAvailable(target) else { return }
            NotificationCenter.default.post(name: reconnected, object: target)
        }
    }
}
