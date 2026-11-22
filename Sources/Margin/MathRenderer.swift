import AppKit
import CoreText

/// Renders a LaTeX math expression into a single attachment image, drawn with
/// AppKit/CoreText against the STIX Two Math/Text faces that ship with macOS.
/// There is no OpenType MATH table reader here: spacing and sizing follow the
/// classic TeX ratios (TeXbook Appendix G), scaled to the font size, which is
/// close enough to correct for a markdown/LaTeX previewer.
enum MathRenderer {
    static func render(_ latex: String, fontSize: CGFloat, display: Bool) -> NSAttributedString {
        let key = "\(Int(fontSize * 4))|\(display ? 1 : 0)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let result = build(latex, fontSize: fontSize, display: display)
        cache.setObject(result, forKey: key)
        return result
    }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 2000
        return cache
    }()

    private static func build(_ latex: String, fontSize: CGFloat, display: Bool) -> NSAttributedString {
        var box: MBox
        do {
            var parser = MathParser(latex)
            let nodes = try parser.parseList()
            try parser.expectEnd()
            let context = MathContext(outerSize: fontSize, style: display ? .display : .text)
            box = MathLayout.hlist(nodes, context)
        } catch {
            box = MathLayout.errorBox(latex, fontSize: fontSize)
        }
        return attachmentString(for: box)
    }

    private static func attachmentString(for box: MBox) -> NSAttributedString {
        let width = max(box.width, 1)
        let height = max(box.height, 0.1)
        let depth = max(box.depth, 0.1)
        let size = NSSize(width: width, height: height + depth)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 0, y: depth)
            box.draw(context)
            context.restoreGState()
            return true
        }
        image.isTemplate = false

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -depth, width: width, height: height + depth)
        return NSAttributedString(attachment: attachment)
    }
}

// MARK: - Boxes

/// A laid-out piece of math: a width, an ascent ("height" in TeX terms) and a
/// descent ("depth"), with a baseline-relative drawing routine. The drawing
/// context is in Core Graphics' native, unflipped coordinate space, so the
/// baseline sits at y = 0 and ascending material has positive y — exactly the
/// convention `CTLineDraw` already uses.
struct MBox {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var depth: CGFloat = 0
    var italicCorrection: CGFloat = 0
    var draw: (CGContext) -> Void = { _ in }

    static func space(_ width: CGFloat) -> MBox { MBox(width: max(0, width)) }

    /// Place `box` so its own origin lands at (x, y) relative to this box's baseline-left.
    static func offset(_ box: MBox, x: CGFloat, y: CGFloat) -> (CGContext) -> Void {
        { context in
            context.saveGState()
            context.translateBy(x: x, y: y)
            box.draw(context)
            context.restoreGState()
        }
    }
}

/// Horizontal styles, following TeX's display/text/script/scriptscript ladder
/// (cramped variants are not modelled separately — a small, acceptable loss of
/// fidelity for things like exponent bases).
enum MathStyle: Int {
    case display = 0, text = 1, script = 2, scriptScript = 3

    var scale: CGFloat {
        switch self {
        case .display, .text: return 1
        case .script: return 0.74
        case .scriptScript: return 0.55
        }
    }

    var sup: MathStyle { self == .display || self == .text ? .script : .scriptScript }
    var sub: MathStyle { .scriptScript }
    /// Style for a fraction's numerator/denominator one level in.
    var numerator: MathStyle { self == .display ? .text : sup }
    var denominator: MathStyle { self == .display ? .text : .scriptScript }
}

struct MathContext {
    var outerSize: CGFloat
    var style: MathStyle

    var fontSize: CGFloat { outerSize * style.scale }

    func styled(_ style: MathStyle) -> MathContext { MathContext(outerSize: outerSize, style: style) }
}

// MARK: - Fonts

enum MathFont {
    private static var cache: [String: CTFont] = [:]
    private static let lock = NSLock()

    static func math(_ size: CGFloat) -> CTFont { named("STIXTwoMath-Regular", size) }

    static func text(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        let traits: NSFontTraitMask = bold && italic ? [.boldFontMask, .italicFontMask] : bold ? .boldFontMask : italic ? .italicFontMask : []
        let key = "STIXTwoText|\(size)|\(traits.rawValue)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let base = NSFontManager.shared.font(withFamily: "STIX Two Text", traits: [], weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size)
        let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
        let ct = font as CTFont
        cache[key] = ct
        return ct
    }

    private static func named(_ name: String, _ size: CGFloat) -> CTFont {
        let key = "\(name)|\(size)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        cache[key] = font
        return font
    }
}

// MARK: - Glyph boxes

enum GlyphDraw {
    /// A box holding a short run of text set in `font`, in the labelColor (so
    /// it follows dark mode). Width is the typographic advance (so spacing
    /// between atoms stays even), but height/depth come from the glyph's
    /// actual ink bounds rather than the font's uniform typographic
    /// ascent/descent — important for placing accents, scripts and fraction
    /// bars against where a glyph like "x" actually visibly ends, not where
    /// a tall ascender like "b" would.
    static func run(_ string: String, font: CTFont) -> MBox {
        guard !string.isEmpty else { return MBox() }
        let attributed = NSAttributedString(string: string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            .foregroundColor: NSColor.labelColor,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let ink = CTLineGetImageBounds(line, nil)
        var height = ascent
        var depth = descent
        if !ink.isNull, ink.height > 0 {
            height = max(ink.maxY, 0.1)
            depth = max(-ink.minY, 0.1)
        }
        var box = MBox(width: width, height: height, depth: depth)
        box.draw = { context in
            context.saveGState()
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return box
    }

    /// A filled rectangle (fraction rules, accent bars, matrix lines).
    static func rule(width: CGFloat, thickness: CGFloat, y: CGFloat) -> MBox {
        var box = MBox(width: max(0, width))
        box.draw = { context in
            context.saveGState()
            NSColor.labelColor.setFill()
            context.fill(CGRect(x: 0, y: y - thickness / 2, width: width, height: thickness))
            context.restoreGState()
        }
        return box
    }

    /// A box that fills a CGPath already built in real point coordinates
    /// (baseline at y=0). Used for small accent glyphs (dots) where a
    /// unit-square + non-uniform-scale approach would turn circles into
    /// flat ellipses.
    static func filledPath(_ path: CGPath, width: CGFloat, height: CGFloat, depth: CGFloat) -> MBox {
        var box = MBox(width: width, height: height, depth: depth)
        box.draw = { context in
            context.saveGState()
            NSColor.labelColor.setFill()
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        return box
    }

    /// A box that strokes a CGPath already built in real point coordinates
    /// (baseline at y=0), with a constant line width unaffected by any later
    /// non-uniform scaling (since none is applied here).
    static func strokePath(_ path: CGPath, width: CGFloat, height: CGFloat, depth: CGFloat, lineWidth: CGFloat) -> MBox {
        var box = MBox(width: width, height: height, depth: depth)
        box.draw = { context in
            context.saveGState()
            NSColor.labelColor.setStroke()
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
        return box
    }
}

// MARK: - Errors

extension MathLayout {
    static func errorBox(_ latex: String, fontSize: CGFloat) -> MBox {
        let text = NSAttributedString(string: latex, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.systemRed,
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        var box = MBox(width: width, height: ascent, depth: descent)
        box.draw = { context in
            context.saveGState()
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return box
    }
}
