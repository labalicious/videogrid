import AppKit

/// What the file browser needs from the grid window it sits in.
protocol FileBrowserDelegate: AnyObject {
    var screenTitles: [String?] { get }                       // one per tile, in screen order
    func browser(_ browser: FileBrowserView, send urls: [URL], toScreen index: Int, play: Bool)
    func browserOpen(_ browser: FileBrowserView, urls: [URL])   // double-click
    func browserShowScreenNumbers(_ show: Bool, highlight: Int?)
    func browserRequestsHide(_ browser: FileBrowserView)
}

/// A folder or media file in the browser. Children are read lazily, when a folder opens.
final class FileNode: NSObject {
    let url: URL
    let isFolder: Bool
    private var cached: [FileNode]?

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }

    var children: [FileNode] {
        if let cached { return cached }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var folders: [FileNode] = [], files: [FileNode] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isPackage != true {
                folders.append(FileNode(url: u, isFolder: true))
            } else if MediaFiles.extensions.contains(u.pathExtension.lowercased()) {
                files.append(FileNode(url: u, isFolder: false))
            }
        }
        let byName: (FileNode, FileNode) -> Bool = {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cached = folders.sorted(by: byName) + files.sorted(by: byName)
        return cached!
    }

    func forget() { cached = nil }
}

/// Sidebar that browses folders for videos. Drag them onto a screen, double-click to play,
/// or right-click → Play on Screen.
final class FileBrowserView: NSVisualEffectView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: FileBrowserDelegate?

    private let outline = NSOutlineView()
    private let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var hideButton: NSButton!
    private let styleButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var root: FileNode
    private var screenMenus: Set<ObjectIdentifier> = []
    private var style = Prefs.browserStyle
    /// Showing the home folder because the starting folder's server or drive wasn't there.
    private var showingFallback: Bool

    static let rootKey = "browserRoot"

    override init(frame: NSRect) {
        let start = StartFolder.resolve()
        root = FileNode(url: start.url, isFolder: true)
        showingFallback = start.isFallback
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        buildUI()
        rebuildFolderMenu()
        rebuildStyleMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(startFolderReconnected(_:)),
                                               name: StartFolder.reconnected, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    /// The starting folder's server came back: switch, unless the user has already gone elsewhere.
    @objc private func startFolderReconnected(_ note: Notification) {
        guard showingFallback, let url = note.object as? URL else { return }
        show(folder: url)
    }

    /// A drive or server came or went: keep the folder menu current, and leave a folder that vanished.
    @objc private func volumesChanged() {
        let start = StartFolder.resolve()
        if !StartFolder.isAvailable(root.url) || (showingFallback && !start.isFallback) {
            show(folder: start.url)
            showingFallback = start.isFallback
        } else {
            rebuildFolderMenu()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: UI

    private func buildUI() {
        folderPopup.controlSize = .small
        folderPopup.font = .systemFont(ofSize: 12)
        folderPopup.target = self
        folderPopup.action = #selector(folderChosen(_:))
        folderPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let up = smallButton("arrow.up", "Enclosing folder", #selector(goUp))
        let refresh = smallButton("arrow.clockwise", "Refresh", #selector(refresh))
        hideButton = smallButton("sidebar.left", "Hide the file browser (⌃⌘S)", #selector(hideClicked))
        styleButton.isBordered = false
        styleButton.controlSize = .small
        styleButton.toolTip = "Show files as names or thumbnails"
        (styleButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        styleButton.setContentHuggingPriority(.required, for: .horizontal)
        styleButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [folderPopup, styleButton, up, refresh, hideButton])
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(outlineResized),
                                               name: NSView.frameDidChangeNotification, object: outline)
        outline.allowsMultipleSelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let hint = NSTextField(wrappingLabelWithString: "Drag videos onto a screen, or right-click → Play on Screen.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        for v in [header, scroll, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func smallButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    /// Points the hide button's icon at the side the browser is on.
    func setSide(left: Bool) {
        hideButton.image = NSImage(systemSymbolName: left ? "sidebar.left" : "sidebar.right",
                                   accessibilityDescription: "Hide")
    }

    // MARK: Names or thumbnails

    private func rebuildStyleMenu() {
        let menu = NSMenu()
        let top = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        top.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: "Show files as")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        menu.addItem(top)
        let label = NSMenuItem(title: "Show Files As", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        for (i, s) in Prefs.BrowserStyle.allCases.enumerated() {
            let item = NSMenuItem(title: s.title, action: #selector(styleChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = s == style ? .on : .off
            item.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        styleButton.menu = menu
    }

    @objc private func styleChosen(_ sender: NSMenuItem) {
        Prefs.browserStyle = Prefs.BrowserStyle.allCases[sender.tag]     // every window follows
    }

    @objc private func prefsChanged() {
        rebuildFolderMenu()                 // the "Start Here in New Windows" tick may have changed
        guard Prefs.browserStyle != style else { return }
        style = Prefs.browserStyle
        rebuildStyleMenu()
        let selection = outline.selectedRowIndexes
        outline.reloadData()
        outline.selectRowIndexes(selection, byExtendingSelection: false)
    }

    @objc private func outlineResized() {
        guard style == .largeThumbnails, outline.numberOfRows > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        }
    }

    // MARK: Folders

    private func rebuildFolderMenu() {
        let fm = FileManager.default
        var places: [URL] = [root.url]
        for dir in [FileManager.SearchPathDirectory.moviesDirectory, .downloadsDirectory, .desktopDirectory, .documentDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first { places.append(u) }
        }
        places.append(fm.homeDirectoryForCurrentUser)
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        places += volumes.filter { $0.path != "/" }

        let menu = NSMenu()
        var seen = Set<String>()
        for (i, u) in places.enumerated() where seen.insert(u.standardizedFileURL.path).inserted {
            let item = NSMenuItem(title: fm.displayName(atPath: u.path), action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = u
            item.toolTip = u.path
            menu.addItem(item)
            if i == 0 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Choose Folder…", action: nil, keyEquivalent: ""))
        let makeDefault = NSMenuItem(title: "Start Here in New Windows", action: nil, keyEquivalent: "")
        makeDefault.representedObject = Self.makeDefaultMarker
        makeDefault.state = root.url.standardizedFileURL == Prefs.browserFolder.standardizedFileURL ? .on : .off
        menu.addItem(makeDefault)
        folderPopup.menu = menu
        folderPopup.selectItem(at: 0)
    }

    private static let makeDefaultMarker = "makeDefault"

    /// Browses a folder. The starting folder for new windows only changes from Settings or
    /// "Start Here in New Windows".
    func show(folder: URL) {
        root = FileNode(url: folder, isFolder: true)
        showingFallback = false
        rebuildFolderMenu()
        outline.reloadData()
    }

    @objc private func folderChosen(_ sender: NSPopUpButton) {
        if sender.selectedItem?.representedObject as? String == Self.makeDefaultMarker {
            folderPopup.selectItem(at: 0)
            Prefs.browserFolder = root.url
            rebuildFolderMenu()
            return
        }
        if let url = sender.selectedItem?.representedObject as? URL {
            if url != root.url { show(folder: url) }
            return
        }
        folderPopup.selectItem(at: 0)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root.url
        panel.prompt = "Browse"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = panel.url { self?.show(folder: u) }
        }
    }

    @objc private func goUp() {
        let parent = root.url.deletingLastPathComponent()
        if parent.path != root.url.path { show(folder: parent) }
    }

    @objc func refresh() {
        func forgetAll(_ n: FileNode) {
            guard n.isFolder else { return }
            if outline.isItemExpanded(n) || n === root { n.children.forEach(forgetAll) }
            n.forget()
        }
        forgetAll(root)
        Thumbnails.shared.forgetFailures()
        outline.reloadData()
    }

    @objc private func hideClicked() { delegate?.browserRequestsHide(self) }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCell ?? {
            let c = FileCell()
            c.identifier = id
            return c
        }()
        cell.show(node, style: node.isFolder ? .names : style)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? FileNode, !node.isFolder else { return 22 }
        switch style {
        case .names: return 22
        case .smallThumbnails: return 46
        case .largeThumbnails:
            let level = CGFloat(outline.level(forItem: node))
            let width = max(80, outline.bounds.width - outline.indentationPerLevel * level - 26)
            return (width * 9 / 16).rounded() + 24
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? FileNode)?.forget()   // re-read next time it opens
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    // MARK: Opening

    private func nodes(at rows: IndexSet) -> [FileNode] {
        rows.compactMap { outline.item(atRow: $0) as? FileNode }
    }

    /// The right-clicked row, plus the rest of the selection if it was part of it.
    private var clickedNodes: [FileNode] {
        let row = outline.clickedRow
        guard row >= 0 else { return nodes(at: outline.selectedRowIndexes) }
        return outline.selectedRowIndexes.contains(row) ? nodes(at: outline.selectedRowIndexes) : nodes(at: [row])
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isFolder {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            return
        }
        delegate?.browserOpen(self, urls: [node.url])
    }

    // MARK: Right-click menu: Play on Screen

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === outline.menu else { return }
        menu.removeAllItems()
        screenMenus = []
        let picked = clickedNodes
        guard !picked.isEmpty else { return }
        // Highlight what was right-clicked, so it's clear what will be sent.
        let row = outline.clickedRow
        if row >= 0, !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        let urls = picked.map(\.url)
        let titles = delegate?.screenTitles ?? []

        for (title, play) in [("Play on Screen", true), ("Add to Screen’s Playlist", false)] {
            let sub = NSMenu()
            sub.delegate = self
            screenMenus.insert(ObjectIdentifier(sub))
            for (i, name) in titles.enumerated() {
                let item = NSMenuItem(title: "Screen \(i + 1)", action: #selector(sendToScreen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ScreenTarget(urls: urls, index: i, play: play)
                if play && i < 9 { item.keyEquivalent = "\(i + 1)"; item.keyEquivalentModifierMask = [] }
                let detail = name ?? "empty"
                let text = NSMutableAttributedString(string: "Screen \(i + 1)", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                text.append(NSAttributedString(string: "   \(detail)", attributes: [
                    .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = text
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        let reveal = menu.addItem(withTitle: "Show in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = urls
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === outline.menu { delegate?.browserShowScreenNumbers(true, highlight: nil) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === outline.menu { delegate?.browserShowScreenNumbers(false, highlight: nil) }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard screenMenus.contains(ObjectIdentifier(menu)) else { return }
        delegate?.browserShowScreenNumbers(true, highlight: (item?.representedObject as? ScreenTarget)?.index)
    }

    @objc private func sendToScreen(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? ScreenTarget else { return }
        delegate?.browser(self, send: t.urls, toScreen: t.index, play: t.play)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        if let urls = sender.representedObject as? [URL] { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    #if VLCGRID_DEBUG
    func menu(forDebug: Void) -> NSMenu? { outline.menu }
    var debugRowCount: Int { outline.numberOfRows }
    /// Shows a folder without saving it as the browser's folder.
    var debugRoot: String { root.url.path + (showingFallback ? " (fallback)" : "") }
    func debugShow(folder: URL) { root = FileNode(url: folder, isFolder: true); outline.reloadData() }
    var debugCells: [String] {
        (0..<outline.numberOfRows).compactMap { r in
            guard let c = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? FileCell else { return nil }
            return "\(c.textField?.stringValue ?? "?") h\(Int(outline.rect(ofRow: r).height)) thumb:\(c.debugHasThumbnail)"
        }
    }
    func debugExpandFirstFolder() {
        if let n = root.children.first(where: \.isFolder) { outline.expandItem(n) }
    }
    /// Opens the right-click menu; `whileOpen` runs from a run-loop timer (GCD blocks wait until it closes).
    func debugOpenMenu(whileOpen: @escaping () -> Void) {
        if let i = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? FileNode)?.isFolder == false }) {
            outline.selectRowIndexes([i], byExtendingSelection: false)
        }
        let t = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { whileOpen(); self?.outline.menu?.cancelTracking() }
        }
        RunLoop.main.add(t, forMode: .common)
        outline.menu?.popUp(positioning: nil, at: NSPoint(x: 60, y: 60), in: outline)
    }
    #endif
}

private final class ScreenTarget: NSObject {
    let urls: [URL], index: Int, play: Bool
    init(urls: [URL], index: Int, play: Bool) { self.urls = urls; self.index = index; self.play = play }
}

/// One row of the browser: an icon and name, or a video thumbnail and name.
final class FileCell: NSTableCellView {
    private let picture = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var url: URL?
    private var style = Prefs.BrowserStyle.names
    private var hasThumbnail = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.masksToBounds = true
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12)
        addSubview(picture)
        addSubview(name)
        imageView = picture
        textField = name
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ node: FileNode, style: Prefs.BrowserStyle) {
        self.style = style
        url = node.url
        name.stringValue = node.url.lastPathComponent
        toolTip = node.url.path
        name.maximumNumberOfLines = style == .smallThumbnails ? 2 : 1
        name.cell?.wraps = style == .smallThumbnails
        name.lineBreakMode = style == .smallThumbnails ? .byWordWrapping : .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        hasThumbnail = false
        if style != .names, let img = Thumbnails.shared.cached(node.url) {
            setThumbnail(img)
        } else {
            picture.image = NSWorkspace.shared.icon(forFile: node.url.path)
            picture.layer?.backgroundColor = nil
            if style != .names {
                let wanted = node.url
                Thumbnails.shared.thumbnail(for: wanted) { [weak self] img in
                    guard let self, self.url == wanted, self.style != .names, let img else { return }
                    self.setThumbnail(img)
                }
            }
        }
        needsLayout = true
    }

    #if VLCGRID_DEBUG
    var debugHasThumbnail: Bool { hasThumbnail }
    #endif

    private func setThumbnail(_ img: NSImage) {
        picture.image = img
        picture.layer?.backgroundColor = NSColor.black.cgColor
        hasThumbnail = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        switch style {
        case .names:
            picture.frame = NSRect(x: 2, y: (b.height - 16) / 2, width: 16, height: 16)
            name.frame = NSRect(x: 23, y: (b.height - 16) / 2, width: max(0, b.width - 25), height: 16)
        case .smallThumbnails:
            let thumb = NSRect(x: 2, y: (b.height - 40) / 2, width: 71, height: 40)
            picture.frame = hasThumbnail ? thumb : thumb.insetBy(dx: 17, dy: 2)
            let h = name.sizeThatFits(NSSize(width: b.width - 84, height: 40)).height
            name.frame = NSRect(x: 80, y: (b.height - min(h, 32)) / 2, width: max(0, b.width - 82), height: min(h, 32))
        case .largeThumbnails:
            let thumb = NSRect(x: 2, y: 20, width: b.width - 6, height: b.height - 22)
            picture.frame = hasThumbnail ? thumb : thumb.insetBy(dx: thumb.width / 2 - 24, dy: thumb.height / 2 - 24)
            name.frame = NSRect(x: 2, y: 1, width: b.width - 6, height: 16)
        }
    }
}
