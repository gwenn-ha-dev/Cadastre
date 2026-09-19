import Foundation

struct RGBA {
    var r: Float, g: Float, b: Float, a: Float

    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: String) {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(text, radix: 16) ?? 0
        r = Float((value >> 16) & 0xFF) / 255
        g = Float((value >> 8) & 0xFF) / 255
        b = Float(value & 0xFF) / 255
        a = 1
    }

    func withAlpha(_ alpha: Float) -> RGBA { RGBA(r, g, b, alpha) }

    /// Blend two colours through OKLab rather than sRGB.
    ///
    /// A straight sRGB mix between blue and red passes through a muddy purple
    /// that reads as its own category; OKLab is perceptually uniform, so the
    /// midpoint looks like the midpoint and lightness moves monotonically —
    /// which is the whole requirement for a sequential or diverging ramp.
    static func mix(_ a: RGBA, _ b: RGBA, _ t: Float) -> RGBA {
        let (l1, a1, b1) = a.oklab, (l2, a2, b2) = b.oklab
        let t = max(0, min(1, t))
        return RGBA(oklab: (l1 + (l2 - l1) * t, a1 + (a2 - a1) * t, b1 + (b2 - b1) * t),
                    alpha: a.a + (b.a - a.a) * t)
    }

    private static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    private static func toGamma(_ c: Float) -> Float {
        let c = max(0, min(1, c))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    var oklab: (Float, Float, Float) {
        let lr = RGBA.toLinear(r), lg = RGBA.toLinear(g), lb = RGBA.toLinear(b)
        let l = cbrtf(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrtf(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrtf(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    init(oklab: (Float, Float, Float), alpha: Float = 1) {
        let (L, A, B) = oklab
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        r = RGBA.toGamma(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        g = RGBA.toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        b = RGBA.toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        a = alpha
    }
}

/// The palette, and the reasoning that fixed its size.
///
/// A treemap is an **all-pairs** form: any two rectangles can end up touching,
/// so every pair of category colours has to be separable — not just neighbours
/// in a legend order.
///
/// The first version took the reference palette's eight hues and found only
/// four of them survived that constraint. That was the wrong conclusion from
/// the right test: the reference palette is a default instance, not a
/// mandate, and the method explicitly expects a project to bring its own ramps
/// and hold them to the same gate. These hues were searched for rather than
/// picked — generated in OKLCH, and grown greedily under a **joint** two-mode
/// constraint, because a set that works on the light surface routinely fails
/// on the dark one where the lightness band is half as wide.
///
/// Measured, all pairs:
///
/// | | light | dark | gate |
/// |---|---|---|---|
/// | CVD separation | 9.3 | 7.6 | 8 target, 6 floor |
/// | Normal vision  | 17.5 | 16.8 | 15 |
///
/// Six hues instead of four, brighter, and with *better* dark-mode separation
/// than the four had (7.6 against 6.9). The dark set still sits in the 6–8
/// band, which is legal only alongside a secondary encoding — hence the
/// permanent legend, the kind named in the inspector, the gutter between
/// fills, and a label on every rectangle big enough to hold one. Those are not
/// decoration to be trimmed later.
///
/// Pushing every step into the light half of the band was tried and costs two
/// hues (five instead of seven before the band correction): variation in
/// lightness is itself part of what keeps colours apart, so spending it all on
/// brightness buys less than it costs.
enum Palette {
    enum Mode { case light, dark }

    /// The families the nine scanned kinds collapse into. Six hues plus a
    /// neutral: images, video and audio each get their own now, which is most
    /// of what the map gained in variety.
    enum Family: Int, CaseIterable {
        case code, document, image, video, audio, data, other

        var label: String {
            switch self {
            case .code: return tr(en: "code", fr: "code")
            case .document: return tr(en: "documents", fr: "documents")
            case .image: return tr(en: "images", fr: "images")
            case .video: return tr(en: "video", fr: "vidéo")
            case .audio: return tr(en: "audio", fr: "audio")
            case .data: return tr(en: "data", fr: "données")
            case .other: return tr(en: "other", fr: "autre")
            }
        }

        static func of(_ kind: TreemapModel.Kind) -> Family {
            switch kind {
            case .code: return .code
            case .document: return .document
            case .image: return .image
            case .video: return .video
            case .audio: return .audio
            case .data, .binary, .archive: return .data
            case .directory, .other: return .other
            }
        }
    }

    // MARK: - Validated tables

    private static let familyLight: [Family: RGBA] = [
        .code: RGBA(hex: "#21ace8"),      // h 234
        .document: RGBA(hex: "#1ca070"),  // h 162
        .image: RGBA(hex: "#fb6bbc"),     // h 348
        .video: RGBA(hex: "#9d63ed"),     // h 300
        .audio: RGBA(hex: "#aeb921"),     // h 114
        .data: RGBA(hex: "#e74b1d"),      // h  36
        // Muted ink rather than a lighter neutral: directory frames are a pale
        // wash of the surface, and a pale "other" was indistinguishable from
        // them — a file read as its own container.
        .other: RGBA(hex: "#898781"),
    ]
    /// Not a darkened copy: each hue re-stepped for the dark surface and
    /// validated as its own set.
    private static let familyDark: [Family: RGBA] = [
        .code: RGBA(hex: "#1a8fc1"),
        .document: RGBA(hex: "#127953"),
        .image: RGBA(hex: "#c23089"),
        .video: RGBA(hex: "#7435bd"),
        .audio: RGBA(hex: "#929c1a"),
        .data: RGBA(hex: "#a6310c"),
        .other: RGBA(hex: "#52514e"),
    ]

    /// Ordinal blue ramp. Five steps in light (the sixth fails the adjacent-ΔL
    /// gate: 0.047 against a 0.06 floor) and five in dark, each mode stepped
    /// for its own surface rather than flipped from the other.
    private static let depthLight = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#104281"].map(RGBA.init(hex:))
    private static let depthDark = ["#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4"].map(RGBA.init(hex:))

    private static let divergingLight = (low: RGBA(hex: "#2a78d6"), mid: RGBA(hex: "#f0efec"), high: RGBA(hex: "#e34948"))
    private static let divergingDark = (low: RGBA(hex: "#3987e5"), mid: RGBA(hex: "#383835"), high: RGBA(hex: "#e66767"))

    /// Fixed across themes and never reused as a series colour.
    static let statusGood = RGBA(hex: "#0ca30c")
    static let statusWarning = RGBA(hex: "#fab219")
    static let statusSerious = RGBA(hex: "#ec835a")
    static let statusCritical = RGBA(hex: "#d03b3b")

    static func surface(_ mode: Mode) -> RGBA {
        mode == .light ? RGBA(hex: "#fcfcfb") : RGBA(hex: "#1a1a19")
    }
    static func plane(_ mode: Mode) -> RGBA {
        mode == .light ? RGBA(hex: "#f9f9f7") : RGBA(hex: "#0d0d0d")
    }
    static func primaryInk(_ mode: Mode) -> RGBA {
        mode == .light ? RGBA(hex: "#0b0b0b") : RGBA(hex: "#ffffff")
    }
    static func secondaryInk(_ mode: Mode) -> RGBA {
        mode == .light ? RGBA(hex: "#52514e") : RGBA(hex: "#c3c2b7")
    }
    static let mutedInk = RGBA(hex: "#898781")

    /// "Nothing to reclaim here" — deliberately recessive, but not so far into
    /// the surface that the structure disappears. On the dark surface a 35 %
    /// mix swallowed every boundary and the map read as one black mass.
    static func keepNeutral(_ mode: Mode) -> RGBA {
        RGBA.mix(surface(mode), mutedInk, mode == .light ? 0.35 : 0.62)
    }

    // MARK: - Lookups

    static func family(_ f: Family, _ mode: Mode) -> RGBA {
        (mode == .light ? familyLight : familyDark)[f] ?? mutedInk
    }

    /// Ordinal: depth clamps at the last step rather than cycling, because a
    /// ramp that wraps stops meaning "deeper".
    static func depth(_ level: Int, _ mode: Mode) -> RGBA {
        let steps = mode == .light ? depthLight : depthDark
        return steps[max(0, min(steps.count - 1, level))]
    }

    /// Sequential: 0 = nothing shared, 1 = every block shared with something
    /// else. Interpolated through the ordinal ramp's endpoints.
    static func sharing(_ fraction: Float, _ mode: Mode) -> RGBA {
        let steps = mode == .light ? depthLight : depthDark
        let position = max(0, min(1, fraction)) * Float(steps.count - 1)
        let low = Int(position)
        let high = min(low + 1, steps.count - 1)
        return RGBA.mix(steps[low], steps[high], position - Float(low))
    }

    /// Diverging: two poles and a neutral middle, so "unchanged" reads as
    /// nothing rather than as a third category.
    static func delta(_ signed: Float, _ mode: Mode) -> RGBA {
        let ramp = mode == .light ? divergingLight : divergingDark
        let t = max(-1, min(1, signed))
        return t >= 0 ? RGBA.mix(ramp.mid, ramp.high, t) : RGBA.mix(ramp.mid, ramp.low, -t)
    }
}
