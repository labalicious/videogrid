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
    private var root: FileNode
    private var screenMenus: Set<ObjectIdentifier> = []

    static let rootKey = "browserRoot"

    override init(frame: NSRect) {
        let saved = UserDefaults.standard.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0) }
        let start = saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        root = FileNode(url: start, isFolder: true)
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        buildUI()
        rebuildFolderMenu()
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
        let header = NSStackView(views: [folderPopup, up, refresh, hideButton])
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
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
        folderPopup.menu = menu
        folderPopup.selectItem(at: 0)
    }

    func show(folder: URL) {
        root = FileNode(url: folder, isFolder: true)
        UserDefaults.standard.set(folder.path, forKey: Self.rootKey)
        rebuildFolderMenu()
        outline.reloadData()
    }

    @objc private func folderChosen(_ sender: NSPopUpButton) {
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
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: 12)
            for v in [image, text] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.imageView = image
            c.textField = text
            return c
        }()
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        cell.toolTip = node.url.path
        return cell
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
