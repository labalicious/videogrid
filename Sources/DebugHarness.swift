#if VLCGRID_DEBUG
import AppKit

/// Test-only: drives zoom on a running grid and saves pictures of the window, so zoom can be
/// checked without a person at the screen. Built only with `DEBUG=1 ./build.sh`.
/// Run with VLCGRID_TEST=<output folder> plus `--layout … --play files…`.
enum DebugHarness {
    static func run(_ grid: GridWindowController, outDir: String) {
        setlinebuf(stdout)
        func at(_ t: Double, _ f: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { f() } }
        }
        func shot(_ name: String) {
            grid.window?.contentView?.layoutSubtreeIfNeeded()
            grid.window?.display()
            guard let w = grid.window, let img = capture(windowID: CGWindowID(w.windowNumber)) else {
                print("DEBUG shot \(name): capture failed"); return
            }
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
            print("DEBUG shot \(name): \(img.width)x\(img.height)")
        }
        let tiles = grid.tiles
        if ProcessInfo.processInfo.environment["VLCGRID_PREFS"] != nil {
            let b = grid.debugBrowser
            if let f = ProcessInfo.processInfo.environment["VLCGRID_FOLDER"] { b.debugShow(folder: URL(fileURLWithPath: f)) }
            let wasVisible = Prefs.browserVisible
            grid.debugSetBrowserVisible(true)
            at(2.0) { print("DEBUG names: \(b.debugCells)"); Prefs.browserStyle = .smallThumbnails }
            at(9.0) { print("DEBUG small: \(b.debugCells)"); shot("p1-small") }
            at(9.5) { Prefs.browserStyle = .largeThumbnails }
            at(11.0) { print("DEBUG large: \(b.debugCells)"); shot("p2-large") }
            at(11.5) {
                SettingsWindowController.shared.showWindow(nil)
                print("DEBUG settings size: \(SettingsWindowController.shared.debugContentSize)")
                (NSApp.delegate as? AppDelegate)?.showAbout(nil)
            }
            at(12.5) {
                for w in NSApp.windows where w.isVisible {
                    print("DEBUG window: \(w.title.isEmpty ? String(describing: type(of: w)) : w.title) \(Int(w.frame.width))x\(Int(w.frame.height))")
                    if let img = capture(windowID: CGWindowID(w.windowNumber)) {
                        let name = w.title.isEmpty ? "about" : w.title.replacingOccurrences(of: " ", with: "-")
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("w-\(name).png"))
                    }
                }
                Prefs.browserStyle = .names
                Prefs.browserVisible = wasVisible
            }
            at(13.5) { NSApp.terminate(nil) }
            return
        }
        if ProcessInfo.processInfo.environment["VLCGRID_SIDEBAR"] != nil {
            func post(_ type: NSEvent.EventType, _ code: UInt16, _ chars: String, raw: UInt = 0) {
                let e = NSEvent.keyEvent(with: type, location: .zero,
                                         modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: grid.window!.windowNumber, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
                NSApp.postEvent(e, atStart: false)
            }
            func state(_ label: String) {
                let p = tiles.map { $0.player.isPlaying ? "▶" : "‖" }.joined()
                let m = tiles.map { $0.player.muted ? "x" : "♪" }.joined()
                print("DEBUG \(label): playing \(p)  audio \(m)  selected \(grid.debugSelectedNumber.map(String.init) ?? "none")")
            }
            func geo(_ label: String) {
                let b = grid.debugBrowser, g = grid.debugGridView; g.window?.contentView?.layoutSubtreeIfNeeded()
                func r(_ f: CGRect) -> String { "x\(Int(f.minX))-\(Int(f.maxX)) w\(Int(f.width)) h\(Int(f.height))" }
                print("DEBUG geo \(label): browser \(b.isHidden ? "hidden" : r(b.frame))  grid \(r(g.frame))  rows \(b.debugRowCount)")
                print("DEBUG geo \(label): tiles \(tiles.map { r($0.frame) })")
            }
            at(3.0) { state("start") }
            at(3.2) { post(.keyDown, 49, " "); post(.keyUp, 49, " ") }                 // space, nothing selected
            at(3.8) { state("space, none selected") }
            at(4.0) { post(.keyDown, 49, " "); post(.keyUp, 49, " ") }
            at(4.6) { state("space again") }
            at(4.8) { grid.debugSelect(1); post(.keyDown, 49, " "); post(.keyUp, 49, " ") }   // tile 2 selected
            at(5.4) { state("space, tile 2 selected") }
            at(5.6) { post(.keyDown, 36, "\r"); post(.keyUp, 36, "\r") }               // return
            at(6.2) { state("return") }
            at(6.4) { post(.keyDown, 36, "\r"); post(.keyUp, 36, "\r") }
            at(7.0) { state("return again") }
            at(7.2) { post(.flagsChanged, 60, "", raw: 0x20104); post(.flagsChanged, 60, "", raw: 0x100) }  // right ⇧ tap
            at(7.6) { state("right shift") }
            at(7.8) { post(.flagsChanged, 56, "", raw: 0x20102); post(.flagsChanged, 56, "", raw: 0x100) }  // left ⇧ tap
            at(8.2) { state("left shift (should not change)") }
            at(8.4) { post(.flagsChanged, 60, "", raw: 0x20104); post(.flagsChanged, 60, "", raw: 0x100) }
            at(8.8) { state("right shift again") }
            at(9.0) { post(.keyDown, 53, "\u{1b}"); post(.keyUp, 53, "\u{1b}") }       // esc deselects
            at(9.4) { state("esc") }
            at(9.6) { tiles.forEach { $0.player.pause() }; grid.debugBrowser.debugExpandFirstFolder() }
            at(10.2) { shot("s1-sidebar-left"); geo("left") }
            at(10.4) { grid.browserShowScreenNumbers(true, highlight: 2) }
            at(11.0) { shot("s2-numbers-highlight-3"); print("DEBUG numbers: \(tiles.map { $0.showsScreenNumber }) highlighted \(tiles.map { $0.screenNumberHighlighted })") }
            at(11.2) { grid.browserShowScreenNumbers(false, highlight: nil) }
            at(11.4) {
                let item = NSMenuItem(); item.tag = 1
                grid.setFileBrowserSide(item)
            }
            at(12.0) { shot("s3-sidebar-right"); geo("right") }
            at(12.2) { grid.debugSetBrowserVisible(false) }
            at(12.8) { shot("s4-sidebar-hidden"); geo("hidden") }
            at(13.0) {
                grid.debugSetBrowserVisible(true)
                let item = NSMenuItem(); item.tag = 0
                grid.setFileBrowserSide(item)
            }
            at(13.5) {
                grid.debugBrowser.debugOpenMenu {
                    shot("s5-context-menu-open")
                    print("DEBUG menu open: numbers shown \(tiles.map { $0.showsScreenNumber })")
                    if let m = grid.debugBrowser.menu(forDebug: ()) {
                        print("DEBUG menu items: \(m.items.map(\.title)); screens: \(m.items.first?.submenu?.items.map { $0.attributedTitle?.string ?? $0.title } ?? [])")
                    }
                }
                print("DEBUG menu closed: numbers shown \(tiles.map { $0.showsScreenNumber })")
            }
            at(14.0) { NSApp.terminate(nil) }
            return
        }
        if ProcessInfo.processInfo.environment["VLCGRID_RESIZE"] != nil {
            let g = grid.debugGridView
            at(3.5) { tiles.forEach { $0.player.pause() } }
            at(4.0) { shot("r0-even") }
            at(4.3) {   // line just right of tile 2, drag right 150pt
                let f = tiles[1].frame
                g.debugDrag(near: CGPoint(x: f.maxX + 2, y: f.midY), by: 150)
            }
            at(5.0) { shot("r1-top-row-only") }
            at(5.3) {   // line just right of tile 4, drag left 100pt
                let f = tiles[3].frame
                g.debugDrag(near: CGPoint(x: f.maxX + 2, y: f.midY), by: -100)
            }
            at(6.0) { shot("r2-whole-line") }
            at(6.3) {   // row divider up 150pt
                g.debugDrag(near: CGPoint(x: g.bounds.width / 2, y: g.bounds.height / 2), by: -150)
            }
            at(7.0) { shot("r3-rows") }
            at(7.5) { NSApp.terminate(nil) }
            return
        }
        if let crops = ProcessInfo.processInfo.environment["VLCGRID_CROPS"] {
            let list = crops.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            at(3.5) { tiles.forEach { $0.player.pause() } }
            for (i, c) in list.enumerated() {
                at(4 + Double(i) * 1.5) { tiles[0].player.debugSetCrop(c) }
                at(5 + Double(i) * 1.5) { shot("crop\(i)") }
            }
            at(5.5 + Double(list.count) * 1.5) { NSApp.terminate(nil) }
            return
        }
        at(3.5) { tiles.forEach { $0.player.pause() } }
        at(4.2) {
            let b = tiles[0].videoView.bounds
            tiles[0].videoView.onSelectionChanged?(CGRect(x: b.width * 0.05, y: b.height * 0.42, width: b.width * 0.35, height: b.height * 0.08))
        }
        at(4.5) { shot("1-unzoomed"); tiles[0].videoView.onSelectionChanged?(nil) }
        at(5.0) {
            let v = tiles[0].videoView, b = v.bounds
            // A box in the left part of the (letterboxed) picture in the tall tile.
            v.zoom(toViewRect: CGRect(x: b.width * 0.05, y: b.height * 0.42, width: b.width * 0.35, height: b.height * 0.08))
            print("DEBUG tile1 box zoom -> \(v.zoom)")
        }
        at(6.5) { shot("2-box-zoom") }
        at(7.0) {
            let v = tiles[0].videoView, b = v.bounds
            v.resetZoom()
            v.setZoom(3, anchor: CGPoint(x: b.width * 0.85, y: b.height * 0.55))   // right side of picture
            let v2 = tiles[1].videoView, b2 = v2.bounds
            v2.setZoom(4, anchor: CGPoint(x: b2.width * 0.15, y: b2.height * 0.2))  // top-left area
        }
        at(8.5) { shot("3-anchor-zoom") }
        at(9.0) { grid.apply(layout: .threeByThree) }
        at(10.0) { shot("4-three-by-three") }
        at(10.5) { NSApp.terminate(nil) }
    }

    /// CGWindowListCreateImage is hidden from new SDKs but still works for the app's own windows.
    private static func capture(windowID: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        return fn(.null, 8, windowID, 1)?.takeRetainedValue()
    }
}
#endif
