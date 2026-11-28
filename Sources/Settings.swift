import AppKit

/// Every user preference, stored in UserDefaults. Changing one posts `Prefs.changed`.
enum Prefs {
    static let changed = Notification.Name("VideoGridPrefsChanged")
    /// Settings → Playback → "Apply to All Open Screens".
    static let applyPlaybackToAll = Notification.Name("VideoGridApplyPlaybackToAll")
    private static var d: UserDefaults { .standard }

    enum Launch: String { case resume, defaults, ask }
    enum Look: String { case dark, light, system }
    enum BrowserStyle: String, CaseIterable {
        case names, smallThumbnails, largeThumbnails
        var title: String {
            switch self {
            case .names: "Names"
            case .smallThumbnails: "Small Thumbnails"
            case .largeThumbnails: "Large Thumbnails"
            }
        }
        var symbol: String {
            switch self {
            case .names: "list.bullet"
            case .smallThumbnails: "list.bullet.rectangle"
            case .largeThumbnails: "rectangle.grid.1x2"
            }
        }
    }

    // MARK: Windows

    static var launch: Launch {
        get {
            switch d.string(forKey: "launch") {
            case "resume", "lastLayout": .resume
            case "defaults": .defaults
            default: .ask
            }
        }
        set { d.set(newValue.rawValue, forKey: "launch"); post() }
    }
    static let windowLimit = 9
    /// The most grid windows open at once.
    static var maxWindows: Int {
        get { let v = d.integer(forKey: "maxWindows"); return v == 0 ? 4 : min(max(v, 1), windowLimit) }
        set { d.set(min(max(newValue, 1), windowLimit), forKey: "maxWindows"); post() }
    }
    /// How many windows "Open my default windows" opens.
    static var windowCount: Int {
        get { min(max(d.integer(forKey: "windowCount"), 1), maxWindows) }
        set { d.set(newValue, forKey: "windowCount"); post() }
    }
    static var sameLayout: Bool {
        get { flag("sameLayout", default: true) }
        set { d.set(newValue, forKey: "sameLayout"); post() }
    }
    /// Default layout patterns: [0] is used by every window when `sameLayout`.
    private static var windowLayouts: [String] {
        get { d.stringArray(forKey: "windowLayouts") ?? [] }
        set { d.set(newValue, forKey: "windowLayouts") }
    }
    static func layoutPattern(forWindow i: Int) -> String {
        let list = windowLayouts
        let p = sameLayout || !list.indices.contains(i) ? list.first : list[i]
        return p.flatMap { try? GridLayout.parse($0) }?.pattern ?? GridLayout.twoByTwo.pattern
    }
    static func layout(forWindow i: Int) -> GridLayout {
        (try? GridLayout.parse(layoutPattern(forWindow: i))) ?? .twoByTwo
    }
    static func setLayoutPattern(_ pattern: String, forWindow i: Int) {
        var list = windowLayouts
        while list.count <= i { list.append(list.first ?? GridLayout.twoByTwo.pattern) }
        list[i] = pattern
        windowLayouts = list
        post()
    }

    /// The default windows in words, e.g. "2 windows with 9 videos in all. Window 1 is 2×2 (4 videos);
    /// Window 2 is XOO/XOO (5 videos, 1 of them bigger)". Reads after "opens".
    static var defaultWindowsSummary: String {
        let count = windowCount
        let layouts = (0..<count).map { layout(forWindow: $0) }
        let total = layouts.reduce(0) { $0 + $1.tiles.count }
        if count == 1 { return "1 window, \(describe(layouts[0]))" }
        let start = "\(count) windows with \(plural(total, "video")) in all"
        if sameLayout { return "\(start), each \(describe(layouts[0]))" }
        let each = layouts.enumerated().map { "Window \($0.offset + 1) is \(describe($0.element))" }
        return "\(start). " + each.joined(separator: "; ")
    }

    private static func describe(_ l: GridLayout) -> String {
        let big = l.tiles.filter { $0.rowSpan > 1 || $0.colSpan > 1 }.count
        let videos = plural(l.tiles.count, "video")
        return big == 0 ? "\(l.title) (\(videos))" : "\(l.pattern) (\(videos), \(big) of them bigger)"
    }

    static func plural(_ n: Int, _ word: String) -> String {
        "\(n.formatted()) \(word)\(n == 1 ? "" : "s")"
    }

    // MARK: Playback

    static var startMuted: Bool {
        get { d.bool(forKey: "startMuted") }
        set { d.set(newValue, forKey: "startMuted"); post() }
    }
    static var defaultRepeat: RepeatMode {
        get { RepeatMode(rawValue: d.integer(forKey: "defaultRepeat")) ?? .off }
        set { d.set(newValue.rawValue, forKey: "defaultRepeat"); post() }
    }
    static var defaultShuffle: Bool {
        get { d.bool(forKey: "defaultShuffle") }
        set { d.set(newValue, forKey: "defaultShuffle"); post() }
    }
    /// Dropping files on a screen plays them right away (otherwise they join the playlist).
    static var dropPlaysNow: Bool {
        get { flag("dropPlaysNow", default: true) }
        set { d.set(newValue, forKey: "dropPlaysNow"); post() }
    }
    /// Maximizing a video silences the others (otherwise they keep playing sound).
    static var muteOthersWhenMaximized: Bool {
        get { flag("muteOthersWhenMaximized", default: true) }
        set { d.set(newValue, forKey: "muteOthersWhenMaximized"); post() }
    }

    // MARK: Sound

    /// The speakers to play through (a Core Audio device UID); nil follows macOS's sound output.
    static var speakerUID: String? { d.string(forKey: "speakerUID") }
    /// The chosen speakers' name, shown while they're disconnected.
    static var speakerName: String? { d.string(forKey: "speakerName") }
    static func setSpeakers(_ device: Speakers.Device?) {
        if let device {
            d.set(device.uid, forKey: "speakerUID")
            d.set(device.name, forKey: "speakerName")
        } else {
            d.removeObject(forKey: "speakerUID")
            d.removeObject(forKey: "speakerName")
        }
        Speakers.refresh()
        post()
    }

    // MARK: Look

    static var look: Look {
        get { Look(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark }
        set { d.set(newValue.rawValue, forKey: "appearance"); applyLook(); post() }
    }
    static var showTitles: Bool {
        get { TileView.showTitles }
        set { TileView.showTitles = newValue; d.set(newValue, forKey: "showTitles"); post() }
    }

    // MARK: File browser

    static var browserStyle: BrowserStyle {
        get { BrowserStyle(rawValue: d.string(forKey: "browserStyle") ?? "") ?? .names }
        set { d.set(newValue.rawValue, forKey: "browserStyle"); post() }
    }
    static var browserOnRight: Bool {
        get { d.bool(forKey: GridWindowController.browserOnRightKey) }
        set { d.set(newValue, forKey: GridWindowController.browserOnRightKey); post() }
    }
    static var browserVisible: Bool {
        get { flag(GridWindowController.browserVisibleKey, default: true) }
        set { d.set(newValue, forKey: GridWindowController.browserVisibleKey) }
    }
    /// The folder the file browser starts in (it may be on a server or drive that isn't connected;
    /// `StartFolder.resolve()` picks what to actually open).
    static var browserFolder: URL {
        get {
            d.string(forKey: FileBrowserView.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        }
        set {
            d.set(newValue.path, forKey: FileBrowserView.rootKey)
            StartFolder.remember(newValue)
            post()
        }
    }

    static func applyLook() {
        switch look {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    /// A yes/no setting that's on until turned off.
    private static func flag(_ key: String, default value: Bool) -> Bool {
        d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }

    static func post() { NotificationCenter.default.post(name: changed, object: nil) }
}

/// Video Grid → Settings… (⌘,): four pages picked with a segmented control.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let pages = ["General", "Windows", "Playback", "File Browser"]
    private lazy var tabs = NSSegmentedControl(labels: pages, trackingMode: .selectOne,
                                               target: self, action: #selector(tabChosen))
    private let container = NSView()
    private var page = 0
    private var handlers: [Handler] = []
    private var picker: LayoutPickerController?
    private var rebuildQueued = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Video Grid Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabs)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 18),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])
        window.contentView = content
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Speakers.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statsChanged), name: Stats.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        let firstTime = window?.isVisible != true
        rebuild()
        if firstTime { window?.center() }
        super.showWindow(sender)
    }

    func show(page: Int) {
        self.page = page
        tabs.selectedSegment = page
        showWindow(nil)
    }

    @objc private func tabChosen() {
        page = tabs.selectedSegment
        rebuild()
    }

    /// Settings can change from elsewhere (menus, the sidebar), so the page is redrawn to match.
    /// Waits until any open menu has closed.
    @objc private func prefsChanged() {
        guard window?.isVisible == true, !rebuildQueued else { return }
        rebuildQueued = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            self?.rebuildQueued = false
            self?.rebuild()
        }
    }

    /// Only the General page shows statistics.
    @objc private func statsChanged() { if page == 0 { prefsChanged() } }

    private func rebuild() {
        guard let window else { return }
        handlers = []
        container.subviews.forEach { $0.removeFromSuperview() }
        let grid: NSGridView
        switch page {
        case 1: grid = windowsPage()
        case 2: grid = playbackPage()
        case 3: grid = browserPage()
        default: grid = generalPage()
        }
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Resize to fit the page, keeping the window's top edge where it is.
        let size = window.contentView!.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // MARK: Pages

    private func generalPage() -> NSGridView {
        let look = popup(["Dark", "Light", "Match System"],
                         selected: [Prefs.Look.dark, .light, .system].firstIndex(of: Prefs.look) ?? 0) {
            Prefs.look = [Prefs.Look.dark, .light, .system][$0]
        }
        let titles = checkbox("Show the number and file name on each video", Prefs.showTitles) { Prefs.showTitles = $0 }
        let launch = popup(["Resume where I left off", "Open my default windows", "Ask which layout to use"],
                           selected: [Prefs.Launch.resume, .defaults, .ask].firstIndex(of: Prefs.launch) ?? 2) {
            Prefs.launch = [Prefs.Launch.resume, .defaults, .ask][$0]
        }
        let launchNote: String
        switch Prefs.launch {
        case .resume:
            launchNote = "Reopens your windows with their playlists, each video where you left it. "
                + "If there's nothing to resume, it opens \(Prefs.defaultWindowsSummary)."
        case .defaults:
            launchNote = "Opens \(Prefs.defaultWindowsSummary)."
        case .ask:
            launchNote = "Shows the layout picker, so you choose the grid each time."
        }

        var rows: [[NSView]] = [
            [heading("Look"), empty],
            [label("Appearance:"), look],
            [empty, titles],
            [heading("Opening"), empty],
            [label("When Video Grid opens:"), launch],
            [empty, note(launchNote)],
        ]
        if Prefs.launch != .ask {
            rows.append([empty, button("Change Default Windows…") { [weak self] in self?.show(page: 1) }])
        }
        let statsHeading = rows.count
        rows += [
            [heading("Statistics"), empty],
            [empty, checkbox("Keep play statistics", Stats.enabled) { Stats.enabled = $0 }],
            [empty, note(Stats.enabled || Stats.isEmpty
                ? "Counts the videos you play and which ones you play most. "
                  + "It's kept only on this Mac and never sent anywhere."
                : "Turned off, so nothing new is counted. What's here stays until you reset it.")],
        ]
        if Stats.enabled || !Stats.isEmpty {
            var played = Prefs.plural(Stats.plays, "time")
            if let since = Stats.since { played += " since " + since.formatted(date: .abbreviated, time: .omitted) }
            let top = Stats.mostPlayed(5).enumerated().map { i, v in
                "\(i + 1).  \(Self.shortName(v.url.lastPathComponent)), \(Prefs.plural(v.plays, "play"))"
            }
            let list = NSTextField(labelWithString: top.isEmpty ? "Nothing yet" : top.joined(separator: "\n"))
            list.toolTip = Stats.mostPlayed(5).map(\.url.path).joined(separator: "\n")
            if top.isEmpty { list.textColor = .secondaryLabelColor }
            let reset = button("Reset Statistics…") { [weak self] in self?.confirmResetStats() }
            reset.isEnabled = !Stats.isEmpty
            rows += [
                [label("Videos played:"), NSTextField(labelWithString: played)],
                [label("Played to the end:"), NSTextField(labelWithString: Prefs.plural(Stats.finished, "time"))],
                [label("Most played:"), list],
                [empty, reset],
            ]
        }
        let grid = NSGridView(views: rows)
        for r in [0, 3, statsHeading] { headingRow(grid, r) }
        return grid
    }

    /// Keeps long file names from stretching the window: "A very long na…me.mp4".
    private static func shortName(_ s: String, max: Int = 46) -> String {
        guard s.count > max else { return s }
        let half = (max - 1) / 2
        return s.prefix(half) + "…" + s.suffix(max - 1 - half)
    }

    private func confirmResetStats() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset your play statistics?"
        alert.informativeText = "This clears the counts and the most played list. It can't be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { Stats.reset() } }
    }

    private func windowsPage() -> NSGridView {
        let max = Prefs.maxWindows
        let count = popup((1...max).map { $0 == 1 ? "1 window" : "\($0) windows" }, selected: Prefs.windowCount - 1) {
            Prefs.windowCount = $0 + 1
        }
        let limit = popup((1...Prefs.windowLimit).map { $0 == 1 ? "1 window" : "\($0) windows" }, selected: max - 1) {
            Prefs.maxWindows = $0 + 1
        }
        let same = radio("The same layout in every window", Prefs.sameLayout) { Prefs.sameLayout = true }
        let different = radio("A different layout for each window", !Prefs.sameLayout) { Prefs.sameLayout = false }

        var rows: [[NSView]] = [
            [heading("Default windows"), empty],
            [label("Open:"), count],
            [label("Layouts:"), same],
            [empty, different],
        ]
        if Prefs.sameLayout {
            rows.append([label("Every window:"), layoutPopup(forWindow: 0)])
        } else {
            for i in 0..<Prefs.windowCount { rows.append([label("Window \(i + 1):"), layoutPopup(forWindow: i)]) }
        }
        let used: String
        switch Prefs.launch {
        case .defaults: used = "They open every time Video Grid starts."
        case .resume: used = "They open when Video Grid starts with nothing to resume."
        case .ask: used = "They aren't used right now: General is set to ask which layout to use when Video Grid opens."
        }
        rows.append([empty, note("That's \(Prefs.defaultWindowsSummary). " + used)])
        rows += [
            [heading("Limit"), empty],
            [label("Allow up to:"), limit],
            [empty, note("File → New Grid Window (⌘N) opens more windows, up to this number.")],
        ]
        let grid = NSGridView(views: rows)
        for r in [0, rows.count - 3] { headingRow(grid, r) }
        return grid
    }

    private func playbackPage() -> NSGridView {
        let rep = popup(["Off", "All (the whole playlist)", "One (the same video)"], selected: Prefs.defaultRepeat.rawValue) {
            Prefs.defaultRepeat = RepeatMode(rawValue: $0) ?? .off
        }
        let random = checkbox("Play in random order", Prefs.defaultShuffle) { Prefs.defaultShuffle = $0 }
        let muted = checkbox("Start muted", Prefs.startMuted) { Prefs.startMuted = $0 }
        let apply = button("Apply to All Open Screens") {
            NotificationCenter.default.post(name: Prefs.applyPlaybackToAll, object: nil)
        }
        let drop = popup(["Plays it right away", "Adds it to the end of the playlist"], selected: Prefs.dropPlaysNow ? 0 : 1) {
            Prefs.dropPlaysNow = $0 == 0
        }
        let silence = radio("Silence the other videos", Prefs.muteOthersWhenMaximized) {
            Prefs.muteOthersWhenMaximized = true
        }
        let keep = radio("Keep the other videos' sound playing", !Prefs.muteOthersWhenMaximized) {
            Prefs.muteOthersWhenMaximized = false
        }

        let devices = Speakers.outputs()
        var names = ["Same as macOS"] + devices.map(\.name)
        var selected = 0
        if let uid = Prefs.speakerUID {
            if let i = devices.firstIndex(where: { $0.uid == uid }) {
                selected = i + 1
            } else {
                names.append("\(Prefs.speakerName ?? "Chosen speakers") (not connected)")
                selected = names.count - 1
            }
        }
        let speakers = popup(names, selected: selected) { i in
            if i == 0 { Prefs.setSpeakers(nil) } else if i <= devices.count { Prefs.setSpeakers(devices[i - 1]) }
        }
        let speakerNote = Prefs.speakerUID == nil
            ? "Sound goes wherever macOS sends it, so it moves to the TV when you AirPlay or cast. "
              + "Choose speakers to keep Video Grid's sound on them."
            : "Video Grid's sound stays on these speakers when you AirPlay or cast to a TV. "
              + "If they're disconnected, sound goes wherever macOS sends it until they're back."

        let grid = NSGridView(views: [
            [heading("New screens"), empty],
            [label("Repeat:"), rep],
            [empty, random],
            [empty, muted],
            [empty, apply],
            [empty, note("Each screen's own repeat, random and speaker buttons still change just that screen.")],
            [heading("Behavior"), empty],
            [label("Dropping a video on a screen:"), drop],
            [label("When a video is maximized:"), silence],
            [empty, keep],
            [heading("Sound"), empty],
            [label("Play sound through:"), speakers],
            [empty, note(speakerNote)],
        ])
        for r in [0, 6, 10] { headingRow(grid, r) }
        return grid
    }

    private func browserPage() -> NSGridView {
        let style = popup(Prefs.BrowserStyle.allCases.map(\.title),
                          selected: Prefs.BrowserStyle.allCases.firstIndex(of: Prefs.browserStyle) ?? 0) {
            Prefs.browserStyle = Prefs.BrowserStyle.allCases[$0]
        }
        let side = popup(["Left", "Right"], selected: Prefs.browserOnRight ? 1 : 0) {
            Prefs.browserOnRight = $0 == 1
            NotificationCenter.default.post(name: GridWindowController.browserSideChanged, object: nil)
        }
        let path = NSPathControl()
        path.pathStyle = .popUp
        path.url = Prefs.browserFolder
        path.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        on(path) { [weak self] p in if let u = p.clickedPathItem?.url { self?.setFolder(u) } }
        let choose = button("Choose…") { [weak self] in self?.chooseFolder() }
        let folderRow = NSStackView(views: [path, choose])
        folderRow.spacing = 8
        var status = "If this folder is on a server that isn't connected or a drive that's unplugged, "
            + "Video Grid tries to reconnect the server and otherwise opens your home folder."
        if !StartFolder.isAvailable(Prefs.browserFolder) { status = "Not connected right now. " + status }
        let visible = checkbox("Show the file browser in new windows", Prefs.browserVisible) { Prefs.browserVisible = $0 }
        return NSGridView(views: [
            [label("Show files as:"), style],
            [label("Position:"), side],
            [label("Start in:"), folderRow],
            [empty, note(status)],
            [empty, visible],
        ])
    }

    // MARK: Folder

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = StartFolder.resolve().url
        panel.prompt = "Choose"
        panel.message = "Choose the folder the file browser starts in. It can be on another disk or a connected server."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = panel.url { self?.setFolder(u) }
        }
    }

    /// Sets the folder new windows start in. Open browsers keep showing what they show now.
    private func setFolder(_ url: URL) { Prefs.browserFolder = url }

    // MARK: Layout popups

    private static let layoutChoices: [(pattern: String, title: String)] =
        [("OO/OO", "2 × 2"), ("OOO/OOO", "3 × 2"), ("OOO/OOO/OOO", "3 × 3")]
        + LayoutPickerController.presets.map { ($0.pattern, "\($0.pattern)    \($0.label)") }

    private func layoutPopup(forWindow i: Int) -> NSPopUpButton {
        let current = Prefs.layoutPattern(forWindow: i)
        var choices = Self.layoutChoices
        if !choices.contains(where: { $0.pattern == current }) { choices.append((current, current)) }
        let p = NSPopUpButton()
        for c in choices {
            p.addItem(withTitle: c.title)
            p.lastItem?.representedObject = c.pattern
        }
        p.menu?.addItem(.separator())
        p.addItem(withTitle: "Custom…")
        p.selectItem(at: choices.firstIndex { $0.pattern == current } ?? 0)
        on(p) { [weak self] p in
            if let pattern = p.selectedItem?.representedObject as? String {
                Prefs.setLayoutPattern(pattern, forWindow: i)
            } else {
                self?.chooseCustomLayout(forWindow: i)
            }
        }
        return p
    }

    private func chooseCustomLayout(forWindow i: Int) {
        guard let window else { return }
        let p = LayoutPickerController(asSheet: true) { layout in Prefs.setLayoutPattern(layout.pattern, forWindow: i) }
        picker = p
        window.beginSheet(p.window!) { [weak self] _ in self?.picker = nil; self?.rebuild() }
    }

    // MARK: Control helpers

    /// Keeps a closure as a control's target.
    private final class Handler: NSObject {
        let run: (Any) -> Void
        init(_ run: @escaping (Any) -> Void) { self.run = run }
        @objc func fire(_ sender: Any) { run(sender) }
    }

    @discardableResult
    private func on<C: NSControl>(_ control: C, _ action: @escaping (C) -> Void) -> C {
        let h = Handler { action($0 as! C) }
        handlers.append(h)
        control.target = h
        control.action = #selector(Handler.fire(_:))
        return control
    }

    private func popup(_ titles: [String], selected: Int, _ action: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.selectItem(at: selected)
        return on(p) { action(max(0, $0.indexOfSelectedItem)) }
    }

    private func checkbox(_ title: String, _ value: Bool, _ action: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = value ? .on : .off
        return on(b) { action($0.state == .on) }
    }

    private func radio(_ title: String, _ value: Bool, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        b.state = value ? .on : .off
        return on(b) { _ in action() }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        on(NSButton(title: title, target: nil, action: nil)) { _ in action() }
    }

    private var empty: NSView { NSGridCell.emptyContentView }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 320
        l.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return l
    }

    private func headingRow(_ grid: NSGridView, _ r: Int) {
        grid.row(at: r).mergeCells(in: NSRange(location: 0, length: 2))
        grid.row(at: r).topPadding = r == 0 ? 0 : 10
        grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading
    }

    #if VLCGRID_DEBUG
    var debugContentSize: NSSize { window?.contentView?.fittingSize ?? .zero }
    #endif
}
