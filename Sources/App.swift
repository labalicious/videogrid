import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var grids: [GridWindowController] = []
    private var picker: LayoutPickerController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.applyLook()
        NSApp.mainMenu = MainMenu.build()
        guard VLC.shared.instance != nil else {
            let alert = NSAlert()
            alert.messageText = "Couldn't start the VLC engine"
            alert.informativeText = "libVLC failed to initialise. Rebuild Video Grid with VLC.app installed in /Applications."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // Command line: VideoGrid --layout XOO/XOO [--play] file1 file2 …  skips the picker.
        let args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--layout"), i + 1 < args.count,
           let layout = try? GridLayout.parse(args[i + 1]) {
            let files = args.enumerated()
                .filter { $0.offset != i && $0.offset != i + 1 && !$0.element.hasPrefix("-") }
                .map { URL(fileURLWithPath: $0.element) }
            pendingURLs += files
            openGrid(layout)
            if args.contains("--play") { grids.last?.playPauseAll(nil) }
            #if VLCGRID_DEBUG
            if let dir = ProcessInfo.processInfo.environment["VLCGRID_TEST"], let g = grids.last {
                DebugHarness.run(g, outDir: dir)
            }
            #endif
        } else if Prefs.launch == .lastLayout, let saved = Prefs.lastLayout,
                  let layout = try? GridLayout.parse(saved) {
            openGrid(layout)
        } else {
            showPicker()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Stop every player off the main thread before quitting (libVLC can crash if torn down mid-playback).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        grids.forEach { $0.shutdown() }
        if Player.backgroundWork.wait(timeout: .now()) == .success { return .terminateNow }
        // A run-loop timer (not the main dispatch queue) so this also works when Quit was
        // triggered from inside a main-queue block.
        let deadline = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 0.05, repeats: true) { t in
            if Player.backgroundWork.wait(timeout: .now()) == .success || Date() > deadline {
                t.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    /// Files opened from Finder or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let grid = grids.last { grid.distribute(urls) } else { pendingURLs += urls }
    }

    private func showPicker() {
        if let w = picker?.window, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let p = LayoutPickerController(asSheet: false) { [weak self] layout in self?.openGrid(layout) }
        picker = p
        p.window?.center()
        p.showWindow(nil)
    }

    private func openGrid(_ layout: GridLayout) {
        Prefs.lastLayout = layout.pattern
        let grid = GridWindowController(layout: layout)
        grid.onClose = { [weak self, weak grid] in self?.grids.removeAll { $0 === grid } }
        grids.append(grid)
        grid.showWindow(nil)
        if !pendingURLs.isEmpty {
            grid.distribute(pendingURLs)
            pendingURLs = []
        }
    }

    @objc func newGridWindow(_ sender: Any?) { showPicker() }

    static let repoURL = URL(string: "https://github.com/labalicious/videogrid")!

    @objc func showAbout(_ sender: Any?) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: center]
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center]
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Several videos side by side in one window.\n", attributes: body))
        credits.append(NSAttributedString(string: "By Kevin Dimond\n", attributes: body.merging(
            [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]) { $1 }))
        credits.append(NSAttributedString(string: "github.com/labalicious/videogrid\n", attributes: body.merging(
            [.link: Self.repoURL]) { $1 }))
        credits.append(NSAttributedString(string: "And built with ❤️ from Claude Code\n", attributes: body.merging(
            [.font: NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)]) { $1 }))
        credits.append(NSAttributedString(string: "Playback by libVLC \(VLC.shared.version) from VideoLAN (LGPL/GPL, source at videolan.org).",
                                          attributes: small))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.showWindow(nil) }
    @objc func openRepo(_ sender: Any?) { NSWorkspace.shared.open(Self.repoURL) }

    @objc func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Video Grid Shortcuts"
        alert.informativeText = """
        Every video, whatever is selected:
        Return  Play / pause all      Right ⇧ (tap)  Mute / unmute all
        Space with no tile selected  Play / pause all

        Click a tile to select it (blue outline); Esc deselects.
        Keys below act on the selected tile:

        Space  Play / pause          S  Stop
        ← →  Back / forward 5 s (with ⇧: 1 s)
        ↑ ↓  Volume                  M  Mute
        N / P  Next / previous item
        L  Repeat: off → all → one   R  Random
        A  Set loop start   B  Set loop end   X  Clear loop
        .  or  E  Step one frame
        F  or double-click  Maximize tile (Esc to go back)

        Zoom: drag a box over the area (⇧-drag when already zoomed),
              or pinch, mouse wheel, ⌘-scroll, = and −
        Pan: drag, or two-finger scroll when zoomed
        0 or double-click: reset zoom

        File browser (⌃⌘S shows / hides): drag videos onto a screen,
              double-click to play, or right-click → Play on Screen
              (each screen shows its number while the menu is open)

        ⌘L  Playlist ↔ video      ⌘O  Add files to tile
        ⌥⌘P  Play / pause all     ⌥⌘R  Restart all from the start
        ⌥⌘M  Mute / unmute all    ⌥-click a speaker: hear only that tile
        ⌥⌘4 / ⌥⌘6 / ⌥⌘9  Switch to 2×2 / 3×2 / 3×3   ⇧⌘L  Custom layout
        ⌘1  Move the selected tile to position 1 (the big one)
        Drag the line between two videos to resize them
              (⌥-drag moves the whole line, double-click evens them out)
        """
        alert.runModal()
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, "Video Grid")
        app.addItem(withTitle: "About Video Grid", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Video Grid", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Video Grid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, "File")
        file.addItem(withTitle: "New Grid Window…", action: #selector(AppDelegate.newGridWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Add Files to Selected Tile…", action: #selector(GridWindowController.addFilesToSelectedTile(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let layout = submenu(in: main, "Layout")
        for (title, pattern, key) in [("2 × 2", "OO/OO", "4"), ("3 × 2", "OOO/OOO", "6"), ("3 × 3", "OOO/OOO/OOO", "9")] {
            let item = layout.addItem(withTitle: title, action: #selector(GridWindowController.applyPresetLayout(_:)), keyEquivalent: key)
            item.representedObject = pattern
            item.keyEquivalentModifierMask = [.command, .option]
        }
        layout.addItem(.separator())
        for p in LayoutPickerController.presets {
            layout.addItem(withTitle: "\(p.pattern)    \(p.label)", action: #selector(GridWindowController.applyPresetLayout(_:)), keyEquivalent: "")
                .representedObject = p.pattern
        }
        layout.addItem(.separator())
        layout.addItem(withTitle: "Custom Layout…", action: #selector(GridWindowController.changeLayout(_:)), keyEquivalent: "L")
        layout.addItem(.separator())
        layout.addItem(withTitle: "Reset Tile Sizes", action: #selector(GridWindowController.resetTileSizes(_:)), keyEquivalent: "")
        layout.addItem(withTitle: "Move Selected Tile to Position 1", action: #selector(GridWindowController.moveSelectedToFirst(_:)), keyEquivalent: "1")

        let edit = submenu(in: main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let playback = submenu(in: main, "Playback")
        playback.addItem(withTitle: "Play / Pause All", action: #selector(GridWindowController.playPauseAll(_:)), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
        playback.addItem(withTitle: "Restart All from the Start", action: #selector(GridWindowController.restartAll(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        playback.addItem(withTitle: "Stop All", action: #selector(GridWindowController.stopAll(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .option]
        playback.addItem(withTitle: "Mute / Unmute All", action: #selector(GridWindowController.toggleMuteAll(_:)), keyEquivalent: "m")
            .keyEquivalentModifierMask = [.command, .option]

        let view = submenu(in: main, "View")
        view.addItem(withTitle: "Show Playlist", action: #selector(GridWindowController.togglePlaylistSelected(_:)), keyEquivalent: "l")
        view.addItem(withTitle: "Show All Playlists", action: #selector(GridWindowController.showAllPlaylists(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Show All Videos", action: #selector(GridWindowController.showAllVideos(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Maximize Selected Tile", action: #selector(GridWindowController.toggleMaximizeSelected(_:)), keyEquivalent: "\r")
        view.addItem(withTitle: "Zoom In", action: #selector(GridWindowController.zoomInSelected(_:)), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: #selector(GridWindowController.zoomOutSelected(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Reset Zoom", action: #selector(GridWindowController.resetZoomSelected(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: "Show Tile Titles", action: #selector(GridWindowController.toggleTitles(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Hide File Browser", action: #selector(GridWindowController.toggleFileBrowser(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        for (title, tag) in [("File Browser on Left", 0), ("File Browser on Right", 1)] {
            view.addItem(withTitle: title, action: #selector(GridWindowController.setFileBrowserSide(_:)), keyEquivalent: "").tag = tag
        }
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let window = submenu(in: main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(in: main, "Help")
        help.addItem(withTitle: "Video Grid Shortcuts", action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "/")
        help.addItem(withTitle: "Video Grid on GitHub", action: #selector(AppDelegate.openRepo(_:)), keyEquivalent: "")
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(in main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
