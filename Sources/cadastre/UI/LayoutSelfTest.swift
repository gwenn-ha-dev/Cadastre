import Foundation

/// Geometry is the one part of a treemap that is worth checking mechanically.
///
/// A layout bug does not crash; it draws something plausible that is quietly
/// lying about proportions, and that is exactly the failure this whole program
/// exists to avoid. These invariants are cheap and catch it.
enum LayoutSelfTest {
    struct Result {
        var checked = 0
        var failures: [String] = []
        var worstProportionError: Double = 0
        var medianAspect: Double = 0
        var rectangles = 0
        var passed: Bool { failures.isEmpty }
    }

    static func run(_ model: TreemapModel, bounds: Rect) -> Result {
        var result = Result()
        let rects = TreemapLayout.compute(model, root: 0, in: bounds)
        result.rectangles = rects.count

        var byNode = [Int32: Rect](minimumCapacity: rects.count)
        for entry in rects { byNode[entry.node] = entry.rect }

        var aspects: [Double] = []
        aspects.reserveCapacity(rects.count)

        for entry in rects {
            let node = Int(entry.node)
            if entry.rect.width > 0 && entry.rect.height > 0 {
                let long = Double(max(entry.rect.width, entry.rect.height))
                let short = Double(min(entry.rect.width, entry.rect.height))
                aspects.append(long / short)
            }
            guard !entry.isLeaf, model.childCount[node] > 0 else { continue }

            let first = Int(model.firstChild[node])
            let count = Int(model.childCount[node])
            var placed: [Rect] = []
            var values: [Double] = []
            for i in first..<(first + count) {
                guard let rect = byNode[Int32(i)] else { continue }
                placed.append(rect)
                values.append(Double(model.value[i]))
            }
            guard placed.count == count, count > 0 else { continue }  // some were culled
            result.checked += 1

            guard let container = TreemapLayout.childArea(of: entry.rect, isRoot: entry.depth == 0) else { continue }
            let parent = entry.rect
            for rect in placed {
                let inside = rect.x >= parent.x - 0.01 && rect.y >= parent.y - 0.01
                    && rect.x + rect.width <= parent.x + parent.width + 0.01
                    && rect.y + rect.height <= parent.y + parent.height + 0.01
                if !inside {
                    result.failures.append(tr(en: "%@: a child leaves its frame", fr: "%@ : un enfant sort du cadre", model.name[node]))
                    break
                }
            }

            let placedArea = placed.reduce(0.0) { $0 + Double($1.area) }

            // Children must fill their container. A layout that leaves a third
            // of a directory blank is not wrong about proportions but is wrong
            // about everything a reader takes from the picture. Only checked on
            // rectangles large enough that the inset and title strip are noise.
            if placedArea < Double(container.area) * 0.99 || placedArea > Double(container.area) * 1.01 {
                result.failures.append(tr(en: "%@: children cover %.1f %% of the inner frame",
                                          fr: "%@ : les enfants couvrent %.1f %% du cadre intérieur",
                                          model.name[node], placedArea / Double(container.area) * 100))
            }

            // Proportionality: each share of the area equals its share of the value.
            let valueTotal = values.reduce(0, +)
            if valueTotal > 0 && placedArea > 0 {
                for (rect, value) in zip(placed, values) {
                    let areaShare = Double(rect.area) / placedArea
                    let valueShare = value / valueTotal
                    let error = abs(areaShare - valueShare)
                    result.worstProportionError = max(result.worstProportionError, error)
                    if error > 0.01 {
                        result.failures.append(tr(en: "%@: wrong proportion (%.3f instead of %.3f)",
                                                  fr: "%@ : proportion fausse (%.3f au lieu de %.3f)",
                                                  model.name[node], areaShare, valueShare))
                        break
                    }
                }
            }

            // Exhaustive overlap check where it is affordable.
            if count <= 200 {
                outer: for i in 0..<placed.count {
                    for j in (i + 1)..<placed.count where overlaps(placed[i], placed[j]) {
                        result.failures.append(tr(en: "%@: two children overlap", fr: "%@ : deux enfants se chevauchent", model.name[node]))
                        break outer
                    }
                }
            }
        }

        aspects.sort()
        if !aspects.isEmpty { result.medianAspect = aspects[aspects.count / 2] }
        return result
    }

    private static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        let slack: Float = 0.01
        return a.x + slack < b.x + b.width && b.x + slack < a.x + a.width
            && a.y + slack < b.y + b.height && b.y + slack < a.y + a.height
    }
}
