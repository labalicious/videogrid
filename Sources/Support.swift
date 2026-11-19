import AppKit

enum TimeFormat {
    /// 83456 → "1:23" (or "1:23.456" when precise).
    static func string(ms: Int64, precise: Bool = false) -> String {
        guard ms >= 0 else { return "--:--" }
        let total = Int(ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var out = h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
        if precise { out += String(format: ".%03ld", Int(ms % 1000)) }
        return out
    }

    /// Accepts "83.5", "1:23", "1:23.456", "1:02:03". Returns milliseconds.
    static func parse(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            seconds = seconds * 60 + v
        }
        return Int64((seconds * 1000).rounded())
    }
}

enum MediaFiles {
    static let extensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "mpg", "mpeg",
        "vob", "ogv", "3gp", "mxf", "divx", "rm", "rmvb", "asf", "f4v", "hevc", "h264", "y4m", "dv",
        "mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "aiff", "alac", "wma",
    ]

    static let audioExtensions: Set<String> = ["mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "aiff", "alac", "wma"]
    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Files are kept as-is; folders are searched recursively for media files (sorted by name).
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else { out.append(url); continue }
            let found = (FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL]) ?? []
            out += found
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return out
    }
}

/// A tile's place in the grid, in cells.
struct TileSpec: Equatable {
    let row: Int, col: Int, rowSpan: Int, colSpan: Int
}

/// A grid described by a pattern such as "XOO/XOO":
/// rows separated by "/", each "O" is its own tile, and any other character repeated
/// across a rectangle of cells is one larger tile.
struct GridLayout: Equatable {
    let pattern: String
    let rows: Int
    let cols: Int
    let tiles: [TileSpec]

    static let maxTiles = 16
    static let twoByTwo = try! GridLayout.parse("OO/OO")
    static let threeByTwo = try! GridLayout.parse("OOO/OOO")
    static let threeByThree = try! GridLayout.parse("OOO/OOO/OOO")

    struct ParseError: Error { let message: String }

    var title: String {
        tiles.allSatisfy { $0.rowSpan == 1 && $0.colSpan == 1 } ? "\(cols)×\(rows)" : pattern
    }

    static func isSingle(_ ch: Character) -> Bool { ch == "O" || ch == "o" || ch == "." }

    static func parse(_ text: String) throws -> GridLayout {
        let rowStrings = text
            .split(whereSeparator: { $0 == "/" || $0 == "\n" || $0 == "," || $0 == ";" })
            .map { String($0.filter { !$0.isWhitespace }) }
            .filter { !$0.isEmpty }
        guard !rowStrings.isEmpty else { throw ParseError(message: "Type a layout, e.g. XOO/XOO") }
        let grid = rowStrings.map { Array($0) }
        let cols = grid[0].count
        guard grid.allSatisfy({ $0.count == cols }) else {
            throw ParseError(message: "Every row needs the same number of cells.")
        }
        guard grid.count <= 8, cols <= 8 else { throw ParseError(message: "Use at most 8 rows and 8 columns.") }

        var tiles: [TileSpec] = []
        var seen = Set<Character>()
        for r in 0..<grid.count {
            for c in 0..<cols {
                let ch = grid[r][c]
                if isSingle(ch) {
                    tiles.append(TileSpec(row: r, col: c, rowSpan: 1, colSpan: 1))
                    continue
                }
                guard !seen.contains(ch) else { continue }
                seen.insert(ch)
                var minR = r, maxR = r, minC = c, maxC = c, count = 0
                for rr in 0..<grid.count {
                    for cc in 0..<cols where grid[rr][cc] == ch {
                        minR = min(minR, rr); maxR = max(maxR, rr)
                        minC = min(minC, cc); maxC = max(maxC, cc)
                        count += 1
                    }
                }
                guard count == (maxR - minR + 1) * (maxC - minC + 1) else {
                    throw ParseError(message: "“\(ch)” has to fill a rectangle to make one big video. Use O for separate videos, e.g. OOO/OOO.")
                }
                tiles.append(TileSpec(row: minR, col: minC, rowSpan: maxR - minR + 1, colSpan: maxC - minC + 1))
            }
        }
        guard tiles.count <= maxTiles else {
            throw ParseError(message: "That's \(tiles.count) videos; the limit is \(maxTiles).")
        }
        return GridLayout(pattern: rowStrings.joined(separator: "/"), rows: grid.count, cols: cols, tiles: tiles)
    }

    /// Tile frames (top-left origin) for a given area.
    func frames(in size: CGSize, gap: CGFloat) -> [CGRect] {
        let cw = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let rh = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return tiles.map { t in
            let x0 = (CGFloat(t.col) * (cw + gap)).rounded()
            let y0 = (CGFloat(t.row) * (rh + gap)).rounded()
            let x1 = (CGFloat(t.col + t.colSpan) * (cw + gap) - gap).rounded()
            let y1 = (CGFloat(t.row + t.rowSpan) * (rh + gap) - gap).rounded()
            return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        }
    }
}
