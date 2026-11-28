import Foundation

/// Play statistics shown in Settings → General. Off until the user turns them on, kept only in
/// Video Grid's settings on this Mac, and cleared with "Reset Statistics…".
enum Stats {
    /// Posted when a count changes or the statistics are reset.
    static let changed = Notification.Name("VideoGridStatsChanged")
    private static var d: UserDefaults { .standard }
    private static let key = "stats"
    /// The most different videos remembered; the least played are dropped past this.
    private static let maxVideos = 2000

    static var enabled: Bool {
        get { d.bool(forKey: "statsEnabled") }
        set {
            d.set(newValue, forKey: "statsEnabled")
            if newValue, since == nil { save(plays: plays, finished: finished, videos: videos, since: Date()) }
            Prefs.post()
        }
    }

    /// Times a video started playing (a video on repeat counts each time round).
    static var plays: Int { stored["plays"] as? Int ?? 0 }
    /// Times a video played all the way to its end.
    static var finished: Int { stored["finished"] as? Int ?? 0 }
    /// When counting started (the first time it was turned on, or the last reset).
    static var since: Date? { stored["since"] as? Date }
    /// Plays per file path.
    static var videos: [String: Int] { stored["videos"] as? [String: Int] ?? [:] }
    static var isEmpty: Bool { plays == 0 && finished == 0 }

    /// The most played videos, most first (ties in name order).
    static func mostPlayed(_ n: Int) -> [(url: URL, plays: Int)] {
        videos.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(n)
            .map { (URL(fileURLWithPath: $0.key), $0.value) }
    }

    static func recordPlay(_ url: URL) {
        guard enabled else { return }
        var v = videos
        v[url.path, default: 0] += 1
        if v.count > maxVideos {
            for (path, _) in v.sorted(by: { $0.value < $1.value }).prefix(v.count - maxVideos) { v[path] = nil }
        }
        save(plays: plays + 1, finished: finished, videos: v, since: since ?? Date())
    }

    static func recordFinished() {
        guard enabled else { return }
        save(plays: plays, finished: finished + 1, videos: videos, since: since ?? Date())
    }

    static func reset() {
        d.removeObject(forKey: key)
        if enabled { save(plays: 0, finished: 0, videos: [:], since: Date()) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static var stored: [String: Any] { d.dictionary(forKey: key) ?? [:] }

    private static func save(plays: Int, finished: Int, videos: [String: Int], since: Date) {
        d.set(["plays": plays, "finished": finished, "videos": videos, "since": since], forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
