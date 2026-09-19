import Foundation

struct Rect {
    var x: Float = 0, y: Float = 0, width: Float = 0, height: Float = 0
    var area: Float { max(0, width) * max(0, height) }
    func contains(_ px: Float, _ py: Float) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

struct TreemapRect {
    var rect: Rect
    var node: Int32
    var depth: UInt8
    /// True when nothing is drawn inside: a file, or a directory whose
    /// rectangle got too small to be worth subdividing.
    var isLeaf: Bool
}

/// Squarified treemap — Bruls, Huizing and van Wijk, 2000.
///
/// The algorithm is twenty-five years old and still the right one: it packs a
/// list of areas into a rectangle while keeping each piece as close to square
/// as it can, which is what makes areas comparable by eye. What dates the old
/// implementations is everything around it, not this.
enum TreemapLayout {
    /// Rectangles smaller than this are drawn but not subdivided. Without a
    /// floor, a home directory lays out two million rectangles to render a few
    /// thousand visible ones.
    static let subdivisionFloor: Float = 16
    /// Below this, a rectangle is not even emitted.
    static let visibilityFloor: Float = 1

    static let defaultLabelBand: Float = 14

    /// The area a directory's children are packed into: its own rectangle,
    /// inset by a hairline so nesting reads, minus a title strip where a title
    /// would actually fit. Returns nil when nothing useful is left.
    ///
    /// Shared with the self-test on purpose — a check that re-derives the
    /// geometry it is checking tests the copy, not the code.
    static func childArea(of rect: Rect, labelBand: Float = defaultLabelBand, isRoot: Bool = false) -> Rect? {
        guard rect.area >= subdivisionFloor else { return nil }
        var inner = rect
        // The root is the whole canvas: its name is already in the breadcrumb
        // and its frame is the window, so neither a title band nor an inset
        // would tell the eye anything.
        if isRoot { return inner.width > 1 && inner.height > 1 ? inner : nil }
        inner.x += 1; inner.y += 1
        inner.width -= 2; inner.height -= 2
        if inner.height > labelBand + 6 && inner.width > 44 {
            inner.y += labelBand
            inner.height -= labelBand
        }
        guard inner.width > 1, inner.height > 1 else { return nil }
        return inner
    }

    static func compute(_ model: TreemapModel, root: Int32, in bounds: Rect,
                        labelBand: Float = defaultLabelBand) -> [TreemapRect] {
        var out: [TreemapRect] = []
        out.reserveCapacity(4096)

        struct Frame { var rect: Rect; var node: Int32; var depth: UInt8 }
        var stack = [Frame(rect: bounds, node: root, depth: 0)]

        var childRects: [Rect] = []
        var childValues: [Float] = []

        while let frame = stack.popLast() {
            let node = Int(frame.node)
            let count = Int(model.childCount[node])

            let inner = count > 0 ? childArea(of: frame.rect, labelBand: labelBand, isRoot: frame.depth == 0) : nil
            out.append(TreemapRect(rect: frame.rect, node: frame.node,
                                   depth: frame.depth, isLeaf: inner == nil))
            guard let inner else { continue }

            let first = Int(model.firstChild[node])
            childValues.removeAll(keepingCapacity: true)
            var total: Double = 0
            for i in first..<(first + count) {
                let v = Float(model.value[i])
                childValues.append(v)
                total += Double(v)
            }
            guard total > 0 else { continue }

            // Scale to the children's own sum, not the parent's: a directory's
            // total also counts its own metadata blocks, and leaving that gap
            // unfilled would show as a sliver of nothing.
            let scale = Float(Double(inner.area) / total)
            for i in childValues.indices { childValues[i] *= scale }

            childRects.removeAll(keepingCapacity: true)
            squarify(childValues, in: inner, into: &childRects)

            // Pushed in reverse so the largest child is popped — and therefore
            // drawn — first.
            for i in stride(from: childRects.count - 1, through: 0, by: -1) {
                let rect = childRects[i]
                guard rect.area >= visibilityFloor else { continue }
                stack.append(Frame(rect: rect, node: Int32(first + i), depth: frame.depth + 1))
            }
        }
        return out
    }

    /// Pack a list of values into a rectangle. The layout pass uses this on
    /// every directory; it is exposed so the app icon can be laid out by the
    /// same algorithm rather than drawn to look like it.
    static func pack(_ values: [Float], in rect: Rect) -> [Rect] {
        let total = values.reduce(0, +)
        guard total > 0 else { return [] }
        let scaled = values.map { $0 * rect.area / total }
        var out: [Rect] = []
        squarify(scaled, in: rect, into: &out)
        return out
    }

    // MARK: - Squarify

    private static func worst(sum: Float, low: Float, high: Float, side: Float) -> Float {
        guard sum > 0, low > 0, side > 0 else { return .greatestFiniteMagnitude }
        let s2 = sum * sum, w2 = side * side
        return max(w2 * high / s2, s2 / (w2 * low))
    }

    private static func squarify(_ values: [Float], in rect: Rect, into out: inout [Rect]) {
        var remaining = rect
        var index = 0
        var rowStart = 0
        var rowSum: Float = 0
        var rowLow = Float.greatestFiniteMagnitude
        var rowHigh: Float = 0

        func flushRow() {
            guard rowSum > 0, index > rowStart else { return }
            place(values[rowStart..<index], sum: rowSum, in: &remaining, into: &out)
            rowStart = index
            rowSum = 0
            rowLow = .greatestFiniteMagnitude
            rowHigh = 0
        }

        while index < values.count {
            let value = values[index]
            guard value > 0 else { index += 1; continue }
            let side = min(remaining.width, remaining.height)

            if rowSum == 0 {
                rowSum = value; rowLow = value; rowHigh = value; index += 1
                continue
            }
            let current = worst(sum: rowSum, low: rowLow, high: rowHigh, side: side)
            let extended = worst(sum: rowSum + value, low: min(rowLow, value),
                                 high: max(rowHigh, value), side: side)
            if extended <= current {
                rowSum += value; rowLow = min(rowLow, value); rowHigh = max(rowHigh, value)
                index += 1
            } else {
                flushRow()
            }
        }
        flushRow()
    }

    private static func place(_ values: ArraySlice<Float>, sum: Float,
                              in remaining: inout Rect, into out: inout [Rect]) {
        if remaining.width >= remaining.height {
            guard remaining.height > 0 else { return }
            let columnWidth = min(sum / remaining.height, remaining.width)
            var y = remaining.y
            for value in values {
                let height = columnWidth > 0 ? value / columnWidth : 0
                out.append(Rect(x: remaining.x, y: y, width: columnWidth, height: height))
                y += height
            }
            remaining.x += columnWidth
            remaining.width -= columnWidth
        } else {
            guard remaining.width > 0 else { return }
            let rowHeight = min(sum / remaining.width, remaining.height)
            var x = remaining.x
            for value in values {
                let width = rowHeight > 0 ? value / rowHeight : 0
                out.append(Rect(x: x, y: remaining.y, width: width, height: rowHeight))
                x += width
            }
            remaining.y += rowHeight
            remaining.height -= rowHeight
        }
    }

    // MARK: - Hit testing

    /// Index of the deepest rectangle covering the point, or -1.
    ///
    /// Returns the index rather than the rectangle because the caller needs
    /// both, and looking the index back up meant a second full scan of forty
    /// thousand entries on every mouse move.
    ///
    /// Walking backwards lets it stop early: rectangles are emitted
    /// parent-before-child, so the last one containing the point is the
    /// deepest, and nothing after it can be deeper.
    static func hitIndex(_ rects: [TreemapRect], at px: Float, _ py: Float) -> Int {
        var index = rects.count - 1
        while index >= 0 {
            if rects[index].rect.contains(px, py) { return index }
            index -= 1
        }
        return -1
    }
}
