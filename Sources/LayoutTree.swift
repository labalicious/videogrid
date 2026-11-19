import AppKit

/// A grid layout turned into nested splits, so the line between two videos can be dragged.
///
/// Rows are split first wherever possible, so each row's dividers move independently:
/// in OOO/OOO, dragging a line in the top row resizes only the top row. Layouts like
/// XOO/XOO become [X | [OO / OO]], so the two top-right videos resize without the two below. Patterns that can't be split into rows/columns
/// (rare pinwheel shapes) keep a fixed, even grid for that part.
final class LayoutNode {
    enum Axis { case rows, columns }   // rows: children stacked top→bottom; columns: left→right

    enum Kind {
        case tile(Int)
        case split(Axis, [LayoutNode])
        case fixedGrid([(index: Int, spec: TileSpec)], rows: Int, cols: Int, r0: Int, c0: Int)
    }

    let kind: Kind
    var weights: [CGFloat]
    let initialWeights: [CGFloat]
    /// Size along the split axis from the last layout pass (for converting drags to weights).
    fileprivate(set) var lastLength: CGFloat = 0

    init(kind: Kind, weights: [CGFloat] = []) {
        self.kind = kind
        self.weights = weights
        self.initialWeights = weights
    }

    func resetSizes() {
        weights = initialWeights
        if case .split(_, let children) = kind { children.forEach { $0.resetSizes() } }
    }

    // MARK: Building

    static func build(_ layout: GridLayout) -> LayoutNode {
        let items = layout.tiles.enumerated().map { (index: $0.offset, spec: $0.element) }
        return build(items, r0: 0, c0: 0, r1: layout.rows, c1: layout.cols)
    }

    private static func build(_ items: [(index: Int, spec: TileSpec)], r0: Int, c0: Int, r1: Int, c1: Int) -> LayoutNode {
        if items.count == 1 { return LayoutNode(kind: .tile(items[0].index)) }

        let rowCuts = (r0 + 1 ..< r1).filter { k in
            items.allSatisfy { !($0.spec.row < k && k < $0.spec.row + $0.spec.rowSpan) }
        }
        if !rowCuts.isEmpty {
            let edges = [r0] + rowCuts + [r1]
            var children: [LayoutNode] = [], weights: [CGFloat] = []
            for (a, b) in zip(edges, edges.dropFirst()) {
                let band = items.filter { $0.spec.row >= a && $0.spec.row < b }
                children.append(build(band, r0: a, c0: c0, r1: b, c1: c1))
                weights.append(CGFloat(b - a))
            }
            return LayoutNode(kind: .split(.rows, children), weights: weights)
        }

        let colCuts = (c0 + 1 ..< c1).filter { k in
            items.allSatisfy { !($0.spec.col < k && k < $0.spec.col + $0.spec.colSpan) }
        }
        if !colCuts.isEmpty {
            // Only cut columns where a tall tile forces it. Neighbouring columns that can still
            // be split into rows stay together, so in XOO/XOO the line between the two top-right
            // videos doesn't also move the two below them.
            let all = [c0] + colCuts + [c1]
            var bands: [(Int, Int)] = []
            for (a, b) in zip(all, all.dropFirst()) {
                if let last = bands.last, hasRowCut(items, r0: r0, r1: r1, c0: last.0, c1: b) {
                    bands[bands.count - 1] = (last.0, b)
                } else {
                    bands.append((a, b))
                }
            }
            let edges = [bands[0].0] + bands.map(\.1)
            var children: [LayoutNode] = [], weights: [CGFloat] = []
            for (a, b) in zip(edges, edges.dropFirst()) {
                let band = items.filter { $0.spec.col >= a && $0.spec.col < b }
                children.append(build(band, r0: r0, c0: a, r1: r1, c1: b))
                weights.append(CGFloat(b - a))
            }
            return LayoutNode(kind: .split(.columns, children), weights: weights)
        }

        return LayoutNode(kind: .fixedGrid(items, rows: r1 - r0, cols: c1 - c0, r0: r0, c0: c0))
    }

    /// Whether the tiles in columns c0..<c1 could be split into rows somewhere.
    private static func hasRowCut(_ items: [(index: Int, spec: TileSpec)], r0: Int, r1: Int, c0: Int, c1: Int) -> Bool {
        let inBand = items.filter { $0.spec.col >= c0 && $0.spec.col < c1 }
        return (r0 + 1 ..< r1).contains { k in
            inBand.allSatisfy { !($0.spec.row < k && k < $0.spec.row + $0.spec.rowSpan) }
        }
    }

    // MARK: Layout

    struct Divider {
        let node: LayoutNode
        let index: Int          // between children index and index+1
        let axis: Axis
        let rect: CGRect        // the gap between the two children
        /// Position of the line along the drag direction (x for columns, y for rows).
        var position: CGFloat { axis == .columns ? rect.midX : rect.midY }
    }

    /// Computes tile frames and the draggable dividers for this subtree.
    func layout(in rect: CGRect, gap: CGFloat, frames: inout [Int: CGRect], dividers: inout [Divider]) {
        switch kind {
        case .tile(let i):
            frames[i] = rect

        case .split(let axis, let children):
            let length = axis == .columns ? rect.width : rect.height
            let available = max(0, length - gap * CGFloat(children.count - 1))
            lastLength = available
            let total = weights.reduce(0, +)
            var offset: CGFloat = 0
            var accumulated: CGFloat = 0
            for (i, child) in children.enumerated() {
                accumulated += weights[i]
                let end = (available * accumulated / total).rounded()
                let size = end - offset
                let start = (axis == .columns ? rect.minX : rect.minY) + offset + gap * CGFloat(i)
                let childRect = axis == .columns
                    ? CGRect(x: start, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: start, width: rect.width, height: size)
                child.layout(in: childRect, gap: gap, frames: &frames, dividers: &dividers)
                if i < children.count - 1 {
                    let gapRect = axis == .columns
                        ? CGRect(x: childRect.maxX, y: rect.minY, width: gap, height: rect.height)
                        : CGRect(x: rect.minX, y: childRect.maxY, width: rect.width, height: gap)
                    dividers.append(Divider(node: self, index: i, axis: axis, rect: gapRect))
                }
                offset = end
            }

        case .fixedGrid(let items, let rows, let cols, let r0, let c0):
            let sub = GridLayout(pattern: "", rows: rows, cols: cols,
                                 tiles: items.map { TileSpec(row: $0.spec.row - r0, col: $0.spec.col - c0,
                                                             rowSpan: $0.spec.rowSpan, colSpan: $0.spec.colSpan) })
            for (item, f) in zip(items, sub.frames(in: rect.size, gap: gap)) {
                frames[item.index] = f.offsetBy(dx: rect.minX, dy: rect.minY)
            }
        }
    }

    /// Moves divider `index` by `delta` points, keeping both neighbours at least `minSize`.
    func moveDivider(_ index: Int, by delta: CGFloat, minSize: CGFloat) {
        guard weights.indices.contains(index + 1), lastLength > 0 else { return }
        let total = weights.reduce(0, +)
        let perPoint = total / lastLength
        var a = weights[index] / perPoint, b = weights[index + 1] / perPoint
        let pair = a + b
        let lo = min(minSize, pair / 2)
        a = min(max(a + delta, lo), pair - lo)
        b = pair - a
        weights[index] = a * perPoint
        weights[index + 1] = b * perPoint
    }

    /// Makes the two neighbours of a divider equal again (double-click on a divider).
    func equalize(_ index: Int) {
        guard weights.indices.contains(index + 1) else { return }
        let pair = weights[index] + weights[index + 1]
        let ia = initialWeights[index], ib = initialWeights[index + 1]
        weights[index] = pair * ia / (ia + ib)
        weights[index + 1] = pair * ib / (ia + ib)
    }
}
