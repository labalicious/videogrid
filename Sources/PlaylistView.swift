import AppKit

/// Table that keeps arrow/delete/return for itself and passes other keys
/// (space, ←/→, letters) up to the tile so playback shortcuts still work.
final class PlaylistTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()                                       // delete, forward delete
        case 125, 126, 115, 119, 116, 121: super.keyDown(with: event)   // ↑ ↓ home end pgup pgdn
        default:
            if event.modifierFlags.contains(.command) { super.keyDown(with: event) }
            else { nextResponder?.keyDown(with: event) }
        }
    }
}

/// A tile's playlist: double-click to play, drag to reorder, drop files/folders to add.
final class PlaylistView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let player: Player
    var tileNumber: Int
    var onPlayRequested: (() -> Void)?
    var onAddRequested: (() -> Void)?

    let table = PlaylistTableView()
    private let scroll = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Drop videos or folders here,\nor click + to add files.")
    private static let rowType = NSPasteboard.PasteboardType("local.videogrid.playlist-row")

    init(player: Player, tileNumber: Int) {
        self.player = player
        self.tileNumber = tileNumber
        super.init(frame: .zero)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let add = headerButton("plus", "Add files or folders… (⌘O)", #selector(addClicked))
        let remove = headerButton("minus", "Remove selected (Delete)", #selector(removeSelected))
        let clear = headerButton("trash", "Clear playlist", #selector(clearAll))
        let header = NSStackView(views: [titleLabel, NSView(), add, remove, clear])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsTypeSelect = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL, Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.menu = makeContextMenu()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        for v in [header, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -20),
        ])
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func headerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Play", action: #selector(playClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove", action: #selector(removeClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealClicked), keyEquivalent: "").target = self
        return menu
    }

    func reload() {
        table.reloadData()
        emptyLabel.isHidden = !player.items.isEmpty
        let n = player.items.count
        titleLabel.stringValue = "Tile \(tileNumber) playlist" + (n > 0 ? "  ·  \(n) item\(n == 1 ? "" : "s")" : "")
    }

    // MARK: Actions

    private func play(row: Int) {
        guard player.items.indices.contains(row) else { return }
        player.play(index: row)
        onPlayRequested?()
    }

    @objc private func doubleClicked() { if table.clickedRow >= 0 { play(row: table.clickedRow) } }
    private func playSelected() { if let r = table.selectedRowIndexes.first { play(row: r) } }
    @objc private func addClicked() { onAddRequested?() }
    @objc private func removeSelected() { player.remove(at: table.selectedRowIndexes) }
    @objc private func clearAll() { player.clear() }

    /// Rows a context-menu command applies to: the selection if the clicked row is in it.
    private var clickedRows: IndexSet {
        let r = table.clickedRow
        guard r >= 0 else { return table.selectedRowIndexes }
        return table.selectedRowIndexes.contains(r) ? table.selectedRowIndexes : IndexSet(integer: r)
    }

    @objc private func playClicked() { if let r = clickedRows.first { play(row: r) } }
    @objc private func removeClicked() { player.remove(at: clickedRows) }
    @objc private func revealClicked() {
        let urls = clickedRows.compactMap { player.items.indices.contains($0) ? player.items[$0] : nil }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { player.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let url = player.items[row]
        let isCurrent = row == player.currentIndex
        cell.textField?.stringValue = (isCurrent ? "▶︎  " : "") + "\(row + 1).  " + url.lastPathComponent
        cell.textField?.font = isCurrent ? .systemFont(ofSize: 12, weight: .bold) : .systemFont(ofSize: 12)
        cell.textField?.textColor = isCurrent ? .controlAccentColor : .labelColor
        cell.toolTip = url.path
        return cell
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        if (info.draggingSource as? NSTableView) === table { return .move }
        return MediaFiles.urls(from: info.draggingPasteboard).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if (info.draggingSource as? NSTableView) === table {
            let rows = (info.draggingPasteboard.pasteboardItems ?? [])
                .compactMap { $0.string(forType: Self.rowType).flatMap { Int($0) } }
            player.move(IndexSet(rows), to: row)
            return true
        }
        let files = MediaFiles.expand(MediaFiles.urls(from: info.draggingPasteboard))
        guard !files.isEmpty else { return false }
        player.insert(files, at: row)
        return true
    }
}

/// Popover for precise A→B loop points.
final class ABLoopViewController: NSViewController {
    private let player: Player
    private let aField = NSTextField()
    private let bField = NSTextField()
    private let status = NSTextField(labelWithString: "")

    init(player: Player) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        for f in [aField, bField] {
            f.placeholderString = "m:ss.sss"
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.target = self
            f.action = #selector(fieldCommitted(_:))
            f.cell?.sendsActionOnEndEditing = true
            f.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        let setA = NSButton(title: "Set to Now", target: self, action: #selector(setAToNow))
        let setB = NSButton(title: "Set to Now", target: self, action: #selector(setBToNow))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "A (start):"), aField, setA],
            [NSTextField(labelWithString: "B (end):"), bField, setB],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let jump = NSButton(title: "Jump to A", target: self, action: #selector(jumpToA))
        let clear = NSButton(title: "Clear Loop", target: self, action: #selector(clearLoop))
        let buttons = NSStackView(views: [jump, clear])

        let title = NSTextField(labelWithString: "A → B Loop")
        title.font = .boldSystemFont(ofSize: 13)
        status.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [title, grid, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        aField.stringValue = player.loopA.map { TimeFormat.string(ms: $0, precise: true) } ?? ""
        bField.stringValue = player.loopB.map { TimeFormat.string(ms: $0, precise: true) } ?? ""
        if player.loopActive {
            status.stringValue = "Looping. Playback jumps back to A when it reaches B."
            status.textColor = .secondaryLabelColor
        } else if player.loopA != nil && player.loopB != nil {
            status.stringValue = "B must be after A. Loop is off."
            status.textColor = .systemRed
        } else {
            status.stringValue = "Set both points to start looping. Times look like 1:23.5"
            status.textColor = .secondaryLabelColor
        }
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        let value = TimeFormat.parse(text)
        if !text.isEmpty && value == nil { NSSound.beep(); refresh(); return }
        if sender === aField { player.setLoop(a: value, b: player.loopB) }
        else { player.setLoop(a: player.loopA, b: value) }
        refresh()
    }

    @objc private func setAToNow() { player.setLoop(a: player.time, b: player.loopB); refresh() }

    @objc private func setBToNow() {
        player.setLoop(a: player.loopA ?? 0, b: player.time)
        if let a = player.loopA, player.loopActive { player.seek(toTime: a) }
        refresh()
    }

    @objc private func jumpToA() { if let a = player.loopA { player.seek(toTime: a) } }
    @objc private func clearLoop() { player.clearLoop(); refresh() }
}
