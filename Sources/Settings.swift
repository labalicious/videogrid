import AppKit

/// Every user preference, stored in UserDefaults. Changing one posts `Prefs.changed`.
enum Prefs {
    static let changed = Notification.Name("VideoGridPrefsChanged")
    private static var d: UserDefaults { .standard }

    enum Launch: String { case ask, lastLayout }
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

    static var launch: Launch {
        get { Launch(rawValue: d.string(forKey: "launch") ?? "") ?? .ask }
        set { d.set(newValue.rawValue, forKey: "launch"); post() }
    }
    static var lastLayout: String? {
        get { d.string(forKey: "lastLayout") }
        set { d.set(newValue, forKey: "lastLayout") }
    }
    static var look: Look {
        get { Look(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark }
        set { d.set(newValue.rawValue, forKey: "appearance"); applyLook(); post() }
    }
    static var browserStyle: BrowserStyle {
        get { BrowserStyle(rawValue: d.string(forKey: "browserStyle") ?? "") ?? .names }
        set { d.set(newValue.rawValue, forKey: "browserStyle"); post() }
    }
    static var browserOnRight: Bool {
        get { d.bool(forKey: GridWindowController.browserOnRightKey) }
        set { d.set(newValue, forKey: GridWindowController.browserOnRightKey); post() }
    }
    static var browserVisible: Bool {
        get { d.object(forKey: GridWindowController.browserVisibleKey) as? Bool ?? true }
        set { d.set(newValue, forKey: GridWindowController.browserVisibleKey) }
    }
    static var browserFolder: URL {
        get {
            let saved = d.string(forKey: FileBrowserView.rootKey).map { URL(fileURLWithPath: $0) }
            return saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        }
        set { d.set(newValue.path, forKey: FileBrowserView.rootKey) }
    }
    static var showTitles: Bool {
        get { TileView.showTitles }
        set { TileView.showTitles = newValue; d.set(newValue, forKey: "showTitles"); post() }
    }
    static var startMuted: Bool {
        get { d.bool(forKey: "startMuted") }
        set { d.set(newValue, forKey: "startMuted"); post() }
    }

    static func applyLook() {
        switch look {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    static func post() { NotificationCenter.default.post(name: changed, object: nil) }
}

/// Video Grid → Settings… (⌘,)
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let launchPopup = NSPopUpButton()
    private let lookPopup = NSPopUpButton()
    private let titlesCheck = NSButton(checkboxWithTitle: "Show the number and file name on each video", target: nil, action: nil)
    private let mutedCheck = NSButton(checkboxWithTitle: "Start new screens muted", target: nil, action: nil)
    private let stylePopup = NSPopUpButton()
    private let sidePopup = NSPopUpButton()
    private let visibleCheck = NSButton(checkboxWithTitle: "Show the file browser in new windows", target: nil, action: nil)
    private let folderLabel = NSPathControl()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Video Grid Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(load), name: Prefs.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        load()
        if window?.isVisible != true { window?.center() }
        super.showWindow(sender)
    }

    private func build() {
        launchPopup.addItems(withTitles: ["Ask which layout to use", "Open the last layout I used"])
        lookPopup.addItems(withTitles: ["Dark", "Light", "Match System"])
        stylePopup.addItems(withTitles: Prefs.BrowserStyle.allCases.map(\.title))
        sidePopup.addItems(withTitles: ["Left", "Right"])
        for c in [launchPopup, lookPopup, stylePopup, sidePopup] as [NSControl] + [titlesCheck, mutedCheck, visibleCheck] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        folderLabel.pathStyle = .popUp
        folderLabel.controlSize = .regular
        folderLabel.url = Prefs.browserFolder
        folderLabel.target = self
        folderLabel.action = #selector(folderPicked(_:))
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folderLabel, choose])
        folderRow.spacing = 8

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        func heading(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return l
        }
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [heading("General"), empty],
            [label("When Video Grid opens:"), launchPopup],
            [label("Appearance:"), lookPopup],
            [empty, titlesCheck],
            [empty, mutedCheck],
            [heading("File Browser"), empty],
            [label("Show files as:"), stylePopup],
            [label("Position:"), sidePopup],
            [label("Start in:"), folderRow],
            [empty, visibleCheck],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for r in [0, 5] {
            grid.row(at: r).mergeCells(in: NSRange(location: 0, length: 2))
            grid.row(at: r).topPadding = r == 0 ? 0 : 12
            grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            folderLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    @objc private func load() {
        launchPopup.selectItem(at: Prefs.launch == .ask ? 0 : 1)
        lookPopup.selectItem(at: [Prefs.Look.dark, .light, .system].firstIndex(of: Prefs.look) ?? 0)
        titlesCheck.state = Prefs.showTitles ? .on : .off
        mutedCheck.state = Prefs.startMuted ? .on : .off
        stylePopup.selectItem(at: Prefs.BrowserStyle.allCases.firstIndex(of: Prefs.browserStyle) ?? 0)
        sidePopup.selectItem(at: Prefs.browserOnRight ? 1 : 0)
        visibleCheck.state = Prefs.browserVisible ? .on : .off
        folderLabel.url = Prefs.browserFolder
    }

    @objc private func changed(_ sender: NSControl) {
        switch sender {
        case launchPopup: Prefs.launch = launchPopup.indexOfSelectedItem == 0 ? .ask : .lastLayout
        case lookPopup: Prefs.look = [Prefs.Look.dark, .light, .system][max(0, lookPopup.indexOfSelectedItem)]
        case titlesCheck: Prefs.showTitles = titlesCheck.state == .on
        case mutedCheck: Prefs.startMuted = mutedCheck.state == .on
        case stylePopup: Prefs.browserStyle = Prefs.BrowserStyle.allCases[max(0, stylePopup.indexOfSelectedItem)]
        case sidePopup:
            Prefs.browserOnRight = sidePopup.indexOfSelectedItem == 1
            NotificationCenter.default.post(name: GridWindowController.browserSideChanged, object: nil)
        case visibleCheck: Prefs.browserVisible = visibleCheck.state == .on
        default: break
        }
    }

    @objc private func folderPicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url { setFolder(url) }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Prefs.browserFolder
        panel.prompt = "Choose"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = panel.url { self?.setFolder(u) }
        }
    }

    /// Sets the folder new windows start in. Open browsers keep showing what they show now.
    private func setFolder(_ url: URL) {
        Prefs.browserFolder = url
        folderLabel.url = url
    }

    #if VLCGRID_DEBUG
    var debugContentSize: NSSize { window?.contentView?.fittingSize ?? .zero }
    #endif
}
