import AppKit

/// Lays tiles out from a GridLayout and lets the lines between them be dragged.
/// Tiles never affect the window size.
final class GridView: NSView {
    private var spec: GridLayout?
    private var tree: LayoutNode?
    private var tiles: [TileView] = []
    private var dividers: [LayoutNode.Divider] = []
    var maximized: TileView? { didSet { needsLayout = true } }

    static let gap: CGFloat = 4
    private static let grab: CGFloat = 3       // extra grab area on each side of a gap
    private static let minTile: CGFloat = 90

    private var dragging: [LayoutNode.Divider] = []
    private var dragLast: CGFloat = 0
    private var hovered: [LayoutNode.Divider] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `resetSizes` false keeps dragged sizes (e.g. when tiles are only swapped).
    func configure(layout: GridLayout, tiles: [TileView], resetSizes: Bool = true) {
        if resetSizes || tree == nil || spec != layout { tree = LayoutNode.build(layout) }
        spec = layout
        self.tiles = tiles
        needsLayout = true
    }

    func resetSizes() {
        tree?.resetSizes()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dividers = []
        defer { window?.invalidateCursorRects(for: self); needsDisplay = true }
        guard let tree else { return }
        if let m = maximized, tiles.contains(where: { $0 === m }) {
            for t in tiles { t.isHidden = t !== m }
            m.frame = bounds
            return
        }
        var frames: [Int: CGRect] = [:]
        tree.layout(in: bounds, gap: Self.gap, frames: &frames, dividers: &dividers)
        for (i, tile) in tiles.enumerated() {
            tile.isHidden = false
            tile.frame = frames[i] ?? .zero
        }
    }

    // MARK: Dividers

    private func hitZone(_ d: LayoutNode.Divider) -> CGRect {
        d.axis == .columns ? d.rect.insetBy(dx: -Self.grab, dy: 0) : d.rect.insetBy(dx: 0, dy: -Self.grab)
    }

    private func divider(at p: CGPoint) -> LayoutNode.Divider? {
        dividers.first { hitZone($0).contains(p) }
    }

    /// With ⌥, every divider on the same line moves together (like a plain grid line).
    private func group(for d: LayoutNode.Divider, wholeLine: Bool) -> [LayoutNode.Divider] {
        guard wholeLine else { return [d] }
        return dividers.filter { $0.axis == d.axis && abs($0.position - d.position) < 1.5 }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return super.hitTest(point) }
        let p = convert(point, from: sv)
        if maximized == nil, divider(at: p) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        guard maximized == nil else { return }
        for d in dividers {
            addCursorRect(hitZone(d), cursor: d.axis == .columns ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let wholeLine = event.modifierFlags.contains(.option)
        let next = divider(at: p).map { group(for: $0, wholeLine: wholeLine) } ?? []
        if next.map(\.rect) != hovered.map(\.rect) { hovered = next }
    }

    override func mouseExited(with event: NSEvent) { if dragging.isEmpty { hovered = [] } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let d = divider(at: p) else { return super.mouseDown(with: event) }
        let line = group(for: d, wholeLine: event.modifierFlags.contains(.option))
        if event.clickCount == 2 {                  // double-click: make the neighbours equal again
            line.forEach { $0.node.equalize($0.index) }
            needsLayout = true
            return
        }
        dragging = line
        hovered = line
        dragLast = d.axis == .columns ? p.x : p.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let first = dragging.first else { return }
        let p = convert(event.locationInWindow, from: nil)
        let now = first.axis == .columns ? p.x : p.y
        let delta = now - dragLast
        guard delta != 0 else { return }
        dragLast = now
        for d in dragging { d.node.moveDivider(d.index, by: delta, minSize: Self.minTile) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Keep highlighting the dragged line(s) at their new place.
        hovered = dividers.filter { nd in dragging.contains { $0.node === nd.node && $0.index == nd.index } }
    }

    override func mouseUp(with event: NSEvent) {
        dragging = []
        mouseMoved(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        for d in hovered { d.rect.fill() }
    }

    #if VLCGRID_DEBUG
    /// Test hook: drag the divider whose line passes nearest `point` by `delta` points.
    func debugDrag(near point: CGPoint, by delta: CGFloat, wholeLine: Bool = false) {
        guard let d = dividers.min(by: { dist($0, point) < dist($1, point) }) else { return }
        for g in group(for: d, wholeLine: wholeLine) { g.node.moveDivider(g.index, by: delta, minSize: Self.minTile) }
        hovered = group(for: d, wholeLine: wholeLine)
        needsLayout = true
    }
    private func dist(_ d: LayoutNode.Divider, _ p: CGPoint) -> CGFloat {
        let r = d.rect
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
    #endif
}

final class GridWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSSplitViewDelegate,
                                  TileViewDelegate, FileBrowserDelegate {
    private let gridView = GridView()
    private let browser = FileBrowserView()
    private let split = NSSplitView()
    private let browserButton = NSButton()
    private var accessory: NSTitlebarAccessoryViewController?
    private(set) var layout: GridLayout
    private(set) var tiles: [TileView] = []
    private var selected: TileView?
    private var timer: Timer?
    private var eventMonitor: Any?
    private var rightShiftDownAt: Date?
    private var picker: LayoutPickerController?
    private var isShutDown = false
    private var arranging = false
    /// Tiles this window muted because another tile was maximized; unmuted again afterwards.
    private var mutedForMaximize: [TileView] = []
    var onWillClose: (() -> Void)?
    var onClose: (() -> Void)?

    static let browserOnRightKey = "browserOnRight"
    static let browserWidthKey = "browserWidth"
    static let browserVisibleKey = "browserVisible"
    static let browserSideChanged = Notification.Name("VideoGridBrowserSideChanged")
    private static let minBrowser: CGFloat = 170

    init(layout: GridLayout) {
        self.layout = layout
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: (screen.width * 0.85).rounded(), height: (screen.height * 0.85).rounded())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        split.isVertical = true
        split.dividerStyle = .thin
        window.contentView = split
        super.init(window: window)
        window.delegate = self
        split.delegate = self
        browser.delegate = self
        browser.isHidden = !Prefs.browserVisible
        setUpTitlebarButton()
        arrangeBrowser()
        window.center()           // the app delegate places it properly (each window has its own place)
        apply(layout: layout)
        startTimer()
        installEventMonitor()
        NotificationCenter.default.addObserver(self, selector: #selector(browserSideChanged),
                                               name: Self.browserSideChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyPlaybackDefaults),
                                               name: Prefs.applyPlaybackToAll, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    func apply(layout: GridLayout) {
        self.layout = layout
        while tiles.count < layout.tiles.count {
            let tile = TileView(number: tiles.count + 1)
            tile.delegate = self
            tiles.append(tile)
            gridView.addSubview(tile)
        }
        while tiles.count > layout.tiles.count {
            let tile = tiles.removeLast()
            tile.shutdown()
            tile.removeFromSuperview()
        }
        if let s = selected, !tiles.contains(where: { $0 === s }) { deselect() }
        setMaximized(nil)
        gridView.configure(layout: layout, tiles: tiles)
        window?.title = "Video Grid: \(layout.title)"
    }

    // MARK: Selection
    //
    // A selected tile (blue outline) gets the keys: Space pauses just that video.
    // With nothing selected, Space plays/pauses every video. Esc deselects.

    private func select(_ tile: TileView) {
        if selected !== tile { selected?.isSelected = false }
        selected = tile
        tile.isSelected = true
        if let fr = window?.firstResponder as? NSView, fr.isDescendant(of: tile) { return }
        window?.makeFirstResponder(tile)
    }

    private func deselect() {
        selected?.isSelected = false
        selected = nil
        if let fr = window?.firstResponder as? NSView, tiles.contains(where: { fr.isDescendant(of: $0) }) {
            window?.makeFirstResponder(nil)
        }
    }

    private var focusIsInSelectedTile: Bool {
        guard let s = selected, let fr = window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: s)
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tiles.forEach { $0.tick() } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Window-wide mouse and keys

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Returns true when the event was used up here.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, (event.window ?? NSApp.keyWindow) === window, window.attachedSheet == nil else {
            rightShiftDownAt = nil
            return false
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            rightShiftDownAt = nil
            // Any click inside a tile (buttons and playlist included) selects it;
            // a click in the file browser deselects.
            let p = gridView.convert(event.locationInWindow, from: nil)
            if gridView.bounds.contains(p),
               let tile = tiles.first(where: { !$0.isHidden && $0.frame.contains(p) }) {
                select(tile)
            } else if !browser.isHidden, browser.bounds.contains(browser.convert(event.locationInWindow, from: nil)) {
                deselect()
            }
            return false

        case .flagsChanged:
            // Tapping right Shift on its own mutes / unmutes everything.
            let rightShiftDown = event.modifierFlags.rawValue & 0x4 != 0   // NX_DEVICERSHIFTKEYMASK
            if event.keyCode == 60 && rightShiftDown {
                let others = event.modifierFlags.intersection([.command, .option, .control])
                rightShiftDownAt = others.isEmpty ? Date() : nil
            } else if event.keyCode == 60, let t = rightShiftDownAt, Date().timeIntervalSince(t) < 1 {
                rightShiftDownAt = nil
                toggleMuteAll(nil)
            } else {
                rightShiftDownAt = nil
            }
            return false

        case .keyDown:
            rightShiftDownAt = nil
            if window.firstResponder is NSText { return false }   // typing in a text field
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return false }
            switch event.keyCode {
            case 36, 76:                       // Return / Enter: every video, whatever is selected
                playPauseAll(nil)
                return true
            case 49 where !focusIsInSelectedTile:   // Space with no tile selected: every video
                playPauseAll(nil)
                return true
            default:
                return false
            }

        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {                      // Esc: leave maximized view, else deselect
            if gridView.maximized != nil { setMaximized(nil) } else { deselect() }
            return
        }
        if let s = selected, s.handleKey(event) { return }
        super.keyDown(with: event)
    }

    // MARK: Lifetime

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        timer?.invalidate()
        timer = nil
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        tiles.forEach { $0.shutdown() }
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
        shutdown()
        onClose?()
    }

    // MARK: File browser sidebar

    private var browserOnRight: Bool { UserDefaults.standard.bool(forKey: Self.browserOnRightKey) }

    /// Puts the browser on the preferred side of the grid.
    private func arrangeBrowser() {
        arranging = true
        defer { arranging = false }
        browser.removeFromSuperview()
        gridView.removeFromSuperview()
        for v in browserOnRight ? [gridView, browser] : [browser, gridView] as [NSView] { split.addSubview(v) }
        browser.setSide(left: !browserOnRight)
        split.adjustSubviews()
        applyBrowserWidth()
        updateBrowserButton()
    }

    private func applyBrowserWidth() {
        guard !browser.isHidden, split.bounds.width > 0 else { return }
        let saved = UserDefaults.standard.object(forKey: Self.browserWidthKey) as? CGFloat ?? 260
        let w = min(max(saved, Self.minBrowser), split.bounds.width / 2)
        let position = browserOnRight ? split.bounds.width - w - split.dividerThickness : w
        arranging = true
        split.setPosition(position, ofDividerAt: 0)
        arranging = false
    }

    private func setBrowserVisible(_ visible: Bool) {
        if !visible, let fr = window?.firstResponder as? NSView, fr.isDescendant(of: browser) {
            window?.makeFirstResponder(nil)
        }
        browser.isHidden = !visible
        UserDefaults.standard.set(visible, forKey: Self.browserVisibleKey)
        split.adjustSubviews()
        applyBrowserWidth()
        updateBrowserButton()
    }

    @objc private func browserSideChanged() { arrangeBrowser() }

    private func setUpTitlebarButton() {
        browserButton.bezelStyle = .texturedRounded
        browserButton.isBordered = false
        browserButton.target = self
        browserButton.action = #selector(toggleFileBrowser(_:))
        browserButton.frame = NSRect(x: 0, y: 0, width: 36, height: 24)
        browserButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    }

    private func updateBrowserButton() {
        browserButton.image = NSImage(systemSymbolName: browserOnRight ? "sidebar.right" : "sidebar.left",
                                      accessibilityDescription: "File browser")
        browserButton.contentTintColor = browser.isHidden ? nil : .controlAccentColor
        browserButton.toolTip = browser.isHidden ? "Show the file browser (⌃⌘S)" : "Hide the file browser (⌃⌘S)"
        let side: NSLayoutConstraint.Attribute = browserOnRight ? .trailing : .leading
        guard accessory?.layoutAttribute != side, let window else { return }
        if let old = accessory, let i = window.titlebarAccessoryViewControllers.firstIndex(of: old) {
            window.removeTitlebarAccessoryViewController(at: i)
        }
        let a = NSTitlebarAccessoryViewController()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        browserButton.frame.origin = NSPoint(x: 4, y: 2)
        holder.addSubview(browserButton)
        a.view = holder
        a.layoutAttribute = side
        window.addTitlebarAccessoryViewController(a)
        accessory = a
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { browser.isHidden }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view !== browser }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        browserOnRight ? max(proposed, splitView.bounds.width / 2) : max(proposed, Self.minBrowser)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        browserOnRight ? min(proposed, splitView.bounds.width - Self.minBrowser - splitView.dividerThickness)
                       : min(proposed, splitView.bounds.width / 2)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, !browser.isHidden, browser.frame.width >= Self.minBrowser - 1,
              NSApp.currentEvent?.type == .leftMouseDragged else { return }
        UserDefaults.standard.set(browser.frame.width, forKey: Self.browserWidthKey)
    }

    // MARK: FileBrowserDelegate

    var screenTitles: [String?] { tiles.map(\.currentTitle) }

    func browser(_ browser: FileBrowserView, send urls: [URL], toScreen index: Int, play: Bool) {
        guard tiles.indices.contains(index) else { return }
        let files = MediaFiles.expand(urls)
        if play { tiles[index].playNow(files) } else { tiles[index].add(files, autoplay: false) }
    }

    func browserOpen(_ browser: FileBrowserView, urls: [URL]) {
        let target = selected ?? tiles.first(where: { $0.player.items.isEmpty }) ?? tiles.first
        target?.playNow(MediaFiles.expand(urls))
    }

    func browserShowScreenNumbers(_ show: Bool, highlight: Int?) {
        for (i, t) in tiles.enumerated() {
            t.showsScreenNumber = show
            t.screenNumberHighlighted = show && i == highlight
        }
        gridView.displayIfNeeded()
    }

    func browserRequestsHide(_ browser: FileBrowserView) { setBrowserVisible(false) }

    // MARK: Files

    /// Files opened from Finder/Dock: one per empty tile, in order; extras go to the selected tile.
    func distribute(_ urls: [URL]) {
        let files = MediaFiles.expand(urls)
        guard !files.isEmpty else { return }
        var empty = tiles.filter { $0.player.items.isEmpty }
        var lastTarget: TileView?
        for file in files {
            let target = empty.isEmpty ? (lastTarget ?? selected ?? tiles.first) : empty.removeFirst()
            target?.add([file], autoplay: false)
            lastTarget = target
        }
    }

    /// With a tile: add to that tile. Without: fill the empty tiles in order.
    private func addFiles(to tile: TileView?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        panel.message = tile.map { "Add videos (or folders) to screen \($0.number)" }
            ?? "Add videos (or folders). They fill the empty screens in order."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            if let tile { tile.add(MediaFiles.expand(panel.urls), autoplay: false) } else { self?.distribute(panel.urls) }
        }
    }

    // MARK: TileViewDelegate

    func tileRequestsMaximizeToggle(_ tile: TileView) {
        setMaximized(gridView.maximized === tile ? nil : tile)
        select(tile)
    }

    /// Shows one tile filling the window (nil: back to the grid). With the Settings option on,
    /// the other tiles go quiet meanwhile and get their sound back afterwards.
    private func setMaximized(_ tile: TileView?) {
        guard gridView.maximized !== tile else { return }
        restoreSilenced()
        gridView.maximized = tile
        if let tile, Prefs.muteOthersWhenMaximized { silenceOthers(except: tile) }
    }

    private func silenceOthers(except tile: TileView) {
        for t in tiles where t !== tile && !t.player.muted {
            t.setMuted(true)
            mutedForMaximize.append(t)
        }
    }

    private func restoreSilenced() {
        for t in mutedForMaximize where t.player.muted && tiles.contains(where: { $0 === t }) { t.setMuted(false) }
        mutedForMaximize = []
    }

    /// The maximize sound setting changed while a video is maximized: apply it now.
    @objc private func prefsChanged() {
        guard let tile = gridView.maximized else { return }
        if Prefs.muteOthersWhenMaximized {
            if mutedForMaximize.isEmpty { silenceOthers(except: tile) }
        } else {
            restoreSilenced()
        }
    }

    func tileRequestsSoloAudio(_ tile: TileView) {
        mutedForMaximize = []
        for t in tiles { t.setMuted(t !== tile) }
    }

    // MARK: Saving and restoring

    func snapshot() -> SavedWindow {
        SavedWindow(layout: layout.pattern, frame: window.map { NSStringFromRect($0.frame) } ?? "",
                    tiles: tiles.map { t in t.snapshot(mutedByApp: mutedForMaximize.contains { $0 === t }) })
    }

    func restore(_ saved: SavedWindow) {
        for (tile, s) in zip(tiles, saved.tiles) { tile.restore(s) }
    }

    @objc private func applyPlaybackDefaults() {
        tiles.forEach { $0.setPlayback(repeat: Prefs.defaultRepeat, shuffle: Prefs.defaultShuffle) }
        tiles.forEach { $0.setMuted(Prefs.startMuted) }
        mutedForMaximize = []
    }

    func tileRequestsAddFiles(_ tile: TileView) { addFiles(to: tile) }

    // MARK: Menu actions

    @objc func addFilesToSelectedTile(_ sender: Any?) { addFiles(to: selected) }

    @objc func changeLayout(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let p = LayoutPickerController(asSheet: true) { [weak self] layout in self?.apply(layout: layout) }
        picker = p
        window.beginSheet(p.window!) { [weak self] _ in self?.picker = nil }
    }

    @objc func applyPresetLayout(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String, let l = try? GridLayout.parse(pattern) else { return }
        apply(layout: l)
    }

    /// Swap the selected tile (and its videos) into position 1, the big tile in layouts like XOO/XOO.
    @objc func moveSelectedToFirst(_ sender: Any?) {
        guard let s = selected, let i = tiles.firstIndex(where: { $0 === s }), i > 0 else { return }
        tiles.swapAt(0, i)
        for (n, t) in tiles.enumerated() { t.number = n + 1 }
        gridView.configure(layout: layout, tiles: tiles, resetSizes: false)
    }

    @objc func resetTileSizes(_ sender: Any?) { gridView.resetSizes() }

    @objc func toggleFileBrowser(_ sender: Any?) { setBrowserVisible(browser.isHidden) }

    /// Tag 0: left, 1: right. Applies to every window.
    @objc func setFileBrowserSide(_ sender: NSMenuItem) {
        Prefs.browserOnRight = sender.tag == 1
        NotificationCenter.default.post(name: Self.browserSideChanged, object: nil)
    }

    #if VLCGRID_DEBUG
    var debugGridView: GridView { gridView }
    var debugBrowser: FileBrowserView { browser }
    func debugSetBrowserVisible(_ v: Bool) { setBrowserVisible(v) }
    func debugKey(_ e: NSEvent) -> Bool { handle(e) }
    var debugSelectedNumber: Int? { selected?.number }
    func debugSelect(_ i: Int?) { if let i { select(tiles[i]) } else { deselect() } }
    #endif

    @objc func playPauseAll(_ sender: Any?) {
        if tiles.contains(where: { $0.player.isPlaying }) {
            tiles.forEach { $0.player.pause() }
        } else {
            tiles.forEach { $0.startPlayback() }
        }
    }

    @objc func restartAll(_ sender: Any?) { tiles.forEach { $0.restartPlayback() } }
    @objc func stopAll(_ sender: Any?) { tiles.forEach { $0.player.stop() } }

    @objc func toggleMuteAll(_ sender: Any?) {
        let anyAudible = tiles.contains { !$0.player.muted }
        tiles.forEach { $0.setMuted(anyAudible) }
        mutedForMaximize = []
    }

    /// Playback → Every Screen: tag 0–2 repeat off/all/one, 3 random on, 4 random off.
    @objc func setEveryScreen(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0...2: tiles.forEach { $0.setPlayback(repeat: RepeatMode(rawValue: sender.tag), shuffle: nil) }
        default: tiles.forEach { $0.setPlayback(repeat: nil, shuffle: sender.tag == 3) }
        }
    }

    @objc func togglePlaylistSelected(_ sender: Any?) { selected?.togglePlaylist() }
    @objc func showAllPlaylists(_ sender: Any?) { tiles.forEach { $0.showsPlaylist = true } }
    @objc func showAllVideos(_ sender: Any?) { tiles.forEach { $0.showsPlaylist = false } }
    @objc func toggleMaximizeSelected(_ sender: Any?) {
        if let s = selected { tileRequestsMaximizeToggle(s) } else { setMaximized(nil) }
    }
    @objc func resetZoomSelected(_ sender: Any?) { selected?.videoView.resetZoom() }
    @objc func zoomInSelected(_ sender: Any?) { selected?.videoView.zoom(by: 1.25) }
    @objc func zoomOutSelected(_ sender: Any?) { selected?.videoView.zoom(by: 0.8) }

    @objc func toggleTitles(_ sender: Any?) {
        Prefs.showTitles.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(applyPresetLayout(_:)):
            let l = (item.representedObject as? String).flatMap { try? GridLayout.parse($0) }
            item.state = (l?.tiles == layout.tiles && l?.rows == layout.rows && l?.cols == layout.cols) ? .on : .off
        case #selector(setEveryScreen(_:)):
            let all: (TileView) -> Bool = item.tag <= 2
                ? { $0.player.repeatMode.rawValue == item.tag } : { $0.player.shuffle == (item.tag == 3) }
            item.state = tiles.allSatisfy(all) ? .on : .off
        case #selector(moveSelectedToFirst(_:)):
            return selected != nil && selected !== tiles.first
        case #selector(toggleTitles(_:)):
            item.state = TileView.showTitles ? .on : .off
        case #selector(toggleMaximizeSelected(_:)):
            item.title = gridView.maximized == nil ? "Maximize Selected Tile" : "Return to Grid"
            return selected != nil || gridView.maximized != nil
        case #selector(togglePlaylistSelected(_:)):
            item.title = (selected?.showsPlaylist ?? false) ? "Show Video" : "Show Playlist"
            return selected != nil
        case #selector(resetZoomSelected(_:)), #selector(zoomInSelected(_:)), #selector(zoomOutSelected(_:)):
            return selected != nil
        case #selector(toggleFileBrowser(_:)):
            item.title = browser.isHidden ? "Show File Browser" : "Hide File Browser"
        case #selector(setFileBrowserSide(_:)):
            item.state = (item.tag == 1) == browserOnRight ? .on : .off
        default:
            break
        }
        return true
    }
}
