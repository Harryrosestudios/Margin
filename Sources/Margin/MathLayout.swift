import AppKit
import CoreText

/// Turns a `MathNode` tree into `MBox`es. Spacing between atoms follows the
/// classic TeX class-pair table (TeXbook Appendix G); fraction/script/radical
/// placement follows TeX's usual ratios, scaled to the font size rather than
/// read from the font's own MATH table.
enum MathLayout {
    // MARK: Horizontal lists

    static func hlist(_ nodes: [MathNode], _ context: MathContext, variant: MathVariant = .italic) -> MBox {
        struct Atom { var box: MBox; var cls: AtomClass }
        var atoms: [Atom] = []

        for node in nodes {
            if case .spacing(let em) = node {
                atoms.append(Atom(box: .space(em * context.fontSize), cls: .ord))
                continue
            }
            var cls = atomClass(of: node)
            if cls == .bin {
                let prior = atoms.last?.cls
                if prior == nil || prior == .bin || prior == .op || prior == .rel || prior == .open || prior == .punct {
                    cls = .ord
                }
            }
            atoms.append(Atom(box: layout(node, context, variant: variant), cls: cls))
        }

        var cursor: CGFloat = 0
        var maxHeight: CGFloat = atoms.isEmpty ? context.fontSize * 0.35 : 0
        var maxDepth: CGFloat = 0
        var draws: [(CGContext) -> Void] = []

        for (idx, atom) in atoms.enumerated() {
            if idx > 0 { cursor += spacingEm(atoms[idx - 1].cls, atom.cls) * context.outerSize }
            let x = cursor
            let box = atom.box
            draws.append { ctx in
                ctx.saveGState()
                ctx.translateBy(x: x, y: 0)
                box.draw(ctx)
                ctx.restoreGState()
            }
            cursor += box.width
            maxHeight = max(maxHeight, box.height)
            maxDepth = max(maxDepth, box.depth)
        }

        var combined = MBox(width: cursor, height: maxHeight, depth: maxDepth)
        combined.draw = { ctx in for d in draws { d(ctx) } }
        return combined
    }

    static func atomClass(of node: MathNode) -> AtomClass {
        switch node {
        case .letter: return .ord
        case .symbol(_, let cls, _, _): return cls
        case .text: return .ord
        case .group(let nodes): return nodes.count == 1 ? atomClass(of: nodes[0]) : .ord
        case .styled(_, let nodes): return nodes.count == 1 ? atomClass(of: nodes[0]) : .ord
        case .frac: return .inner
        case .sqrt: return .ord
        case .scripts(let base, _, _, _): return atomClass(of: base)
        case .delimited: return .inner
        case .accent: return .ord
        case .spacing: return .ord
        case .matrix: return .inner
        case .error: return .ord
        }
    }

    private static func opInfo(_ node: MathNode) -> (isOp: Bool, limits: Bool)? {
        switch node {
        case .symbol(_, let cls, let upright, let limits): return (cls == .op && !upright) ? (true, limits) : nil
        case .group(let nodes) where nodes.count == 1: return opInfo(nodes[0])
        default: return nil
        }
    }

    /// TeX's inter-atom spacing table, in ems (thin = 3mu, med = 4mu, thick = 5mu, 18mu = 1em).
    private static func spacingEm(_ left: AtomClass, _ right: AtomClass) -> CGFloat {
        let thin: CGFloat = 0.1667, med: CGFloat = 0.2222, thick: CGFloat = 0.2778
        switch (left, right) {
        case (.ord, .op), (.op, .ord), (.op, .op), (.close, .op): return thin
        case (.ord, .bin), (.close, .bin), (.inner, .bin): return med
        case (.ord, .rel), (.op, .rel), (.close, .rel), (.inner, .rel): return thick
        case (.ord, .inner), (.op, .inner), (.close, .inner): return thin
        case (.bin, .ord), (.bin, .op), (.bin, .open), (.bin, .inner): return med
        case (.rel, .ord), (.rel, .op), (.rel, .open), (.rel, .inner): return thick
        case (.punct, _): return thin
        case (.inner, .ord): return thin
        default: return 0
        }
    }

    private static func scaled(_ box: MBox, _ factor: CGFloat) -> MBox {
        guard factor != 1 else { return box }
        var out = MBox(width: box.width * factor, height: box.height * factor, depth: box.depth * factor,
                        italicCorrection: box.italicCorrection * factor)
        out.draw = { ctx in
            ctx.saveGState()
            ctx.scaleBy(x: factor, y: factor)
            box.draw(ctx)
            ctx.restoreGState()
        }
        return out
    }

    // MARK: Single atoms

    static func layout(_ node: MathNode, _ context: MathContext, variant: MathVariant) -> MBox {
        switch node {
        case .letter(let c):
            let s = MathAlphabet.transform(String(c), variant: variant)
            return GlyphDraw.run(s, font: MathFont.math(context.fontSize))

        case .symbol(let glyph, let cls, let upright, _):
            if upright {
                return GlyphDraw.run(glyph, font: MathFont.text(context.fontSize))
            }
            var box = GlyphDraw.run(glyph, font: MathFont.math(context.fontSize))
            if cls == .op, context.style == .display { box = scaled(box, 1.25) }
            return box

        case .text(let s):
            return GlyphDraw.run(s, font: MathFont.text(context.outerSize))

        case .group(let nodes):
            return hlist(nodes, context, variant: variant)

        case .styled(let v, let nodes):
            return hlist(nodes, context, variant: v)

        case .frac(let num, let den, let rule, let left, let right):
            return layoutFrac(num, den, rule: rule, left: left, right: right, context: context, variant: variant)

        case .sqrt(let index, let radicand):
            return layoutSqrt(index, radicand, context: context, variant: variant)

        case .scripts(let base, let sub, let sup, let limits):
            return layoutScripts(base, sub: sub, sup: sup, limitsOverride: limits, context: context, variant: variant)

        case .delimited(let left, let body, let right):
            let inner = hlist(body, context, variant: variant)
            return layoutDelimited(left: left, right: right, inner: inner, context: context)

        case .accent(let cmd, let base):
            return layoutAccent(cmd, base, context: context, variant: variant)

        case .spacing(let em):
            return .space(em * context.fontSize)

        case .matrix(let kind, let rows):
            return layoutMatrix(kind, rows, context: context, variant: variant)

        case .error(let text):
            return errorBox(text, fontSize: context.fontSize)
        }
    }

    // MARK: Scripts

    private static func layoutScripts(
        _ base: MathNode, sub: [MathNode]?, sup: [MathNode]?, limitsOverride: Bool?,
        context: MathContext, variant: MathVariant
    ) -> MBox {
        let baseBox = layout(base, context, variant: variant)
        let fontSize = context.fontSize

        let op = opInfo(base)
        let useLimits = limitsOverride ?? (op?.limits ?? false)
        if useLimits, context.style == .display, (sub != nil || sup != nil) {
            return layoutLimits(baseBox, sub: sub, sup: sup, context: context, variant: variant)
        }

        let supBox = sup.map { hlist($0, context.styled(context.style.sup), variant: variant) }
        let subBox = sub.map { hlist($0, context.styled(context.style.sub), variant: variant) }

        let scriptSpace = fontSize * 0.05
        var supShift = max(fontSize * 0.36, baseBox.height - fontSize * 0.18)
        var subShift = max(fontSize * 0.18, baseBox.depth + fontSize * 0.08)

        if let supBox, let subBox {
            let gap = (supShift - supBox.depth) - (-subShift + subBox.height)
            let minGap = fontSize * 0.15
            if gap < minGap {
                let needed = (minGap - gap) / 2
                supShift += needed
                subShift += needed
            }
        }

        let scriptsWidth = max(supBox?.width ?? 0, subBox?.width ?? 0)
        let scriptX = baseBox.width + baseBox.italicCorrection

        var box = MBox()
        box.width = scriptX + scriptsWidth + (scriptsWidth > 0 ? scriptSpace : 0)
        let supTop = supBox.map { supShift + $0.height } ?? 0
        let subBottom = subBox.map { subShift - $0.depth } ?? 0
        box.height = max(baseBox.height, supTop)
        box.depth = max(baseBox.depth, subBottom)
        box.draw = { ctx in
            baseBox.draw(ctx)
            ctx.saveGState()
            ctx.translateBy(x: scriptX, y: 0)
            if let supBox {
                ctx.saveGState(); ctx.translateBy(x: 0, y: supShift); supBox.draw(ctx); ctx.restoreGState()
            }
            if let subBox {
                ctx.saveGState(); ctx.translateBy(x: 0, y: -subShift); subBox.draw(ctx); ctx.restoreGState()
            }
            ctx.restoreGState()
        }
        return box
    }

    /// Stacked sup/sub above and below an operator, for display-style `\sum_{}^{}` etc.
    private static func layoutLimits(_ baseBox: MBox, sub: [MathNode]?, sup: [MathNode]?, context: MathContext, variant: MathVariant) -> MBox {
        let fontSize = context.fontSize
        let supBox = sup.map { hlist($0, context.styled(context.style.sup), variant: variant) }
        let subBox = sub.map { hlist($0, context.styled(context.style.sub), variant: variant) }
        let gap = fontSize * 0.18

        let width = max(baseBox.width, supBox?.width ?? 0, subBox?.width ?? 0)
        var height = baseBox.height
        var depth = baseBox.depth
        var supY: CGFloat = 0
        var subY: CGFloat = 0
        if let supBox {
            supY = baseBox.height + gap + supBox.depth
            height = supY + supBox.height
        }
        if let subBox {
            subY = -(baseBox.depth + gap + subBox.height)
            depth = -subY + subBox.depth
        }

        var box = MBox(width: width, height: height, depth: depth)
        let baseX = (width - baseBox.width) / 2
        let supX = supBox.map { (width - $0.width) / 2 }
        let subX = subBox.map { (width - $0.width) / 2 }
        box.draw = { ctx in
            ctx.saveGState(); ctx.translateBy(x: baseX, y: 0); baseBox.draw(ctx); ctx.restoreGState()
            if let supBox, let supX { ctx.saveGState(); ctx.translateBy(x: supX, y: supY); supBox.draw(ctx); ctx.restoreGState() }
            if let subBox, let subX { ctx.saveGState(); ctx.translateBy(x: subX, y: subY); subBox.draw(ctx); ctx.restoreGState() }
        }
        return box
    }

    // MARK: Fractions

    private static func layoutFrac(
        _ num: [MathNode], _ den: [MathNode], rule: Bool, left: String?, right: String?,
        context: MathContext, variant: MathVariant
    ) -> MBox {
        let fontSize = context.fontSize
        let numBox = hlist(num, context.styled(context.style.numerator), variant: variant)
        let denBox = hlist(den, context.styled(context.style.denominator), variant: variant)

        let axis = fontSize * 0.25
        let thickness = rule ? max(fontSize * 0.05, 0.6) : 0
        let gap = context.style == .display ? fontSize * 0.1 : fontSize * 0.06

        let numShift = axis + thickness / 2 + gap + numBox.depth
        let denShift = -axis + thickness / 2 + gap + denBox.height

        let width = max(numBox.width, denBox.width) + fontSize * 0.2
        var box = MBox()
        box.width = width
        box.height = numShift + numBox.height
        box.depth = denShift + denBox.depth
        let numX = (width - numBox.width) / 2
        let denX = (width - denBox.width) / 2
        box.draw = { ctx in
            ctx.saveGState(); ctx.translateBy(x: numX, y: numShift); numBox.draw(ctx); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: denX, y: -denShift); denBox.draw(ctx); ctx.restoreGState()
            if rule {
                NSColor.labelColor.setFill()
                ctx.fill(CGRect(x: 0, y: axis - thickness / 2, width: width, height: thickness))
            }
        }
        if let left, let right {
            return layoutDelimited(left: left, right: right, inner: box, context: context)
        }
        return box
    }

    // MARK: Radicals

    private static func layoutSqrt(_ index: [MathNode]?, _ radicand: [MathNode], context: MathContext, variant: MathVariant) -> MBox {
        let fontSize = context.fontSize
        let radicandBox = hlist(radicand, context, variant: variant)
        let desiredHeight = radicandBox.height + fontSize * 0.18
        let desiredDepth = radicandBox.depth + fontSize * 0.02
        let neededSize = desiredHeight + desiredDepth

        let natural = GlyphDraw.run("√", font: MathFont.math(fontSize))
        let naturalSize = max(natural.height + natural.depth, 0.001)
        let factor = max(neededSize / naturalSize, 1)
        let signHeight = natural.height * factor
        let signDepth = natural.depth * factor
        let widthScale: CGFloat = 1 + min(max(factor - 1, 0), 1.5) * 0.18
        let signWidth = natural.width * widthScale

        var sign = MBox(width: signWidth, height: signHeight, depth: signDepth)
        sign.draw = { ctx in
            ctx.saveGState()
            ctx.scaleBy(x: widthScale, y: factor)
            natural.draw(ctx)
            ctx.restoreGState()
        }

        let barThickness = max(fontSize * 0.045, 0.6)
        let gap = fontSize * 0.06
        let radicandX = signWidth + gap
        let barWidth = radicandBox.width + fontSize * 0.1
        let barY = signHeight

        var box = MBox()
        box.width = radicandX + barWidth
        box.height = max(signHeight, radicandBox.height + barThickness)
        box.depth = max(signDepth, radicandBox.depth)
        box.draw = { ctx in
            sign.draw(ctx)
            NSColor.labelColor.setFill()
            ctx.fill(CGRect(x: signWidth, y: barY - barThickness, width: barWidth, height: barThickness))
            ctx.saveGState(); ctx.translateBy(x: radicandX, y: 0); radicandBox.draw(ctx); ctx.restoreGState()
        }

        guard let index else { return box }
        let indexBox = hlist(index, context.styled(.scriptScript), variant: variant)
        let mainX = max(indexBox.width * 0.7, fontSize * 0.1)
        var withIndex = MBox()
        withIndex.width = mainX + box.width
        withIndex.height = max(box.height, indexBox.height + fontSize * 0.25)
        withIndex.depth = box.depth
        withIndex.draw = { ctx in
            ctx.saveGState(); ctx.translateBy(x: 0, y: fontSize * 0.25); indexBox.draw(ctx); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: mainX, y: 0); box.draw(ctx); ctx.restoreGState()
        }
        return withIndex
    }

    // MARK: Stretchy delimiters

    static func layoutDelimited(left: String, right: String, inner: MBox, context: MathContext) -> MBox {
        let fontSize = context.fontSize
        let targetSize = max(inner.height, inner.depth) * 2
        let pad = fontSize * 0.08

        func delim(_ glyph: String) -> MBox {
            guard !glyph.isEmpty else { return MBox(width: fontSize * 0.1) }
            let natural = GlyphDraw.run(glyph, font: MathFont.math(fontSize))
            let naturalSize = max(natural.height + natural.depth, 0.001)
            let factor = max(targetSize / naturalSize, 1)
            var box = MBox(width: natural.width, height: natural.height * factor, depth: natural.depth * factor)
            box.draw = { ctx in
                ctx.saveGState()
                ctx.scaleBy(x: 1, y: factor)
                natural.draw(ctx)
                ctx.restoreGState()
            }
            return box
        }

        let leftBox = delim(left)
        let rightBox = delim(right)

        var box = MBox()
        box.width = leftBox.width + pad + inner.width + pad + rightBox.width
        box.height = max(leftBox.height, inner.height, rightBox.height)
        box.depth = max(leftBox.depth, inner.depth, rightBox.depth)
        let innerX = leftBox.width + pad
        box.draw = { ctx in
            leftBox.draw(ctx)
            ctx.saveGState(); ctx.translateBy(x: innerX, y: 0); inner.draw(ctx); ctx.restoreGState()
            ctx.saveGState(); ctx.translateBy(x: innerX + inner.width + pad, y: 0); rightBox.draw(ctx); ctx.restoreGState()
        }
        return box
    }

    // MARK: Accents

    private static func stretchHorizontally(_ box: MBox, to width: CGFloat) -> MBox {
        let scaleX = width / max(box.width, 0.001)
        var out = MBox(width: width, height: box.height, depth: box.depth)
        out.draw = { ctx in
            ctx.saveGState()
            ctx.scaleBy(x: scaleX, y: 1)
            box.draw(ctx)
            ctx.restoreGState()
        }
        return out
    }

    /// These build paths in real point coordinates (baseline at y=0), rather
    /// than a unit square scaled at draw time, so strokes keep a constant
    /// width and the dot accents stay circular regardless of the base's width.
    private static func hatPath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: width * 0.2, y: height * 0.15))
        p.addLine(to: CGPoint(x: width * 0.5, y: height * 0.95))
        p.addLine(to: CGPoint(x: width * 0.8, y: height * 0.15))
        return p
    }
    private static func checkPath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: width * 0.2, y: height * 0.95))
        p.addLine(to: CGPoint(x: width * 0.5, y: height * 0.15))
        p.addLine(to: CGPoint(x: width * 0.8, y: height * 0.95))
        return p
    }
    private static func tildePath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: width * 0.03, y: height * 0.35))
        p.addCurve(to: CGPoint(x: width * 0.5, y: height * 0.75),
                   control1: CGPoint(x: width * 0.2, y: height * 0.95), control2: CGPoint(x: width * 0.3, y: height * 0.15))
        p.addCurve(to: CGPoint(x: width * 0.97, y: height * 0.35),
                   control1: CGPoint(x: width * 0.7, y: height * 1.1), control2: CGPoint(x: width * 0.8, y: height * 0.15))
        return p
    }
    private static func brevePath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let r = max(height * 1.3, width * 0.22)
        p.addArc(center: CGPoint(x: width * 0.5, y: height * 1.0 + r * 0.55), radius: r,
                  startAngle: .pi * 0.78, endAngle: .pi * 0.22, clockwise: true)
        return p
    }
    private static func dotPath(width: CGFloat, height: CGFloat) -> CGPath {
        let r = max(height * 0.45, 1)
        let cx = width / 2
        return CGPath(ellipseIn: CGRect(x: cx - r, y: height * 0.5, width: r * 2, height: r * 2), transform: nil)
    }
    private static func ddotPath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let r = max(height * 0.4, 1)
        let spacing = max(width * 0.12, r * 2.2)
        let cx = width / 2
        p.addEllipse(in: CGRect(x: cx - spacing - r, y: height * 0.5, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: cx + spacing - r, y: height * 0.5, width: r * 2, height: r * 2))
        return p
    }
    private static func vecPath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: width * 0.05, y: height * 0.3)); p.addLine(to: CGPoint(x: width * 0.95, y: height * 0.3))
        p.addLine(to: CGPoint(x: width * 0.7, y: height * 0.65))
        p.move(to: CGPoint(x: width * 0.95, y: height * 0.3)); p.addLine(to: CGPoint(x: width * 0.7, y: -height * 0.05))
        return p
    }
    private static func vecLeftPath(width: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: width * 0.95, y: height * 0.3)); p.addLine(to: CGPoint(x: width * 0.05, y: height * 0.3))
        p.addLine(to: CGPoint(x: width * 0.3, y: height * 0.65))
        p.move(to: CGPoint(x: width * 0.05, y: height * 0.3)); p.addLine(to: CGPoint(x: width * 0.3, y: -height * 0.05))
        return p
    }

    private static func layoutAccent(_ command: String, _ baseNodes: [MathNode], context: MathContext, variant: MathVariant) -> MBox {
        let fontSize = context.fontSize
        let baseBox = hlist(baseNodes, context, variant: variant)
        let accentHeight = fontSize * 0.22
        let gap = fontSize * 0.08
        let width = max(baseBox.width, fontSize * 0.5)

        var accentBox: MBox
        var extraTop = accentHeight + gap
        var extraBottom: CGFloat = 0
        let isUnder = command == "underline" || command == "underbrace"

        switch command {
        case "bar", "overline":
            let thickness = max(fontSize * 0.04, 0.6)
            accentBox = GlyphDraw.rule(width: width, thickness: thickness, y: thickness / 2)
            accentBox.height = thickness; accentBox.depth = 0
            extraTop = gap
        case "underline":
            let thickness = max(fontSize * 0.04, 0.6)
            accentBox = GlyphDraw.rule(width: width, thickness: thickness, y: thickness / 2)
            accentBox.height = thickness; accentBox.depth = 0
            extraBottom = gap
        case "hat", "widehat":
            let h = accentHeight
            accentBox = GlyphDraw.strokePath(hatPath(width: width, height: h), width: width, height: h, depth: 0, lineWidth: max(fontSize * 0.06, 1))
        case "check":
            let h = accentHeight
            accentBox = GlyphDraw.strokePath(checkPath(width: width, height: h), width: width, height: h, depth: 0, lineWidth: max(fontSize * 0.06, 1))
        case "tilde", "widetilde":
            let h = accentHeight
            accentBox = GlyphDraw.strokePath(tildePath(width: width, height: h), width: width, height: h, depth: 0, lineWidth: max(fontSize * 0.06, 1))
        case "breve":
            let h = accentHeight * 0.8
            accentBox = GlyphDraw.strokePath(brevePath(width: width, height: h), width: width, height: h, depth: 0, lineWidth: max(fontSize * 0.06, 1))
        case "dot":
            let h = accentHeight * 0.55
            accentBox = GlyphDraw.filledPath(dotPath(width: width, height: h), width: width, height: h, depth: 0)
        case "ddot":
            let h = accentHeight * 0.55
            accentBox = GlyphDraw.filledPath(ddotPath(width: width, height: h), width: width, height: h, depth: 0)
        case "vec", "overrightarrow":
            let h = accentHeight * 1.1
            accentBox = GlyphDraw.strokePath(vecPath(width: width, height: h), width: width, height: h, depth: 0, lineWidth: max(fontSize * 0.055, 1))
        case "overleftarrow":
            let h = accentHeight * 1.1
            accentBox = GlyphDraw.strokePath(vecLeftPath(width: width, height: h), width: width, height: h, depth: 0, lineWidth: max(fontSize * 0.055, 1))
        case "overbrace":
            let natural = GlyphDraw.run("⏞", font: MathFont.math(fontSize))
            accentBox = stretchHorizontally(natural, to: width)
            extraTop = max(natural.height + natural.depth, fontSize * 0.15) + gap
        case "underbrace":
            let natural = GlyphDraw.run("⏟", font: MathFont.math(fontSize))
            accentBox = stretchHorizontally(natural, to: width)
            extraBottom = max(natural.height + natural.depth, fontSize * 0.15) + gap
        default:
            accentBox = MBox(width: width)
        }

        var box = MBox()
        box.width = width
        if isUnder {
            box.height = baseBox.height
            box.depth = baseBox.depth + extraBottom + accentBox.height + accentBox.depth
            let accentY = -(baseBox.depth + extraBottom + accentBox.height)
            box.draw = { ctx in
                baseBox.draw(ctx)
                ctx.saveGState(); ctx.translateBy(x: 0, y: accentY); accentBox.draw(ctx); ctx.restoreGState()
            }
        } else {
            box.height = baseBox.height + extraTop + accentBox.height + accentBox.depth
            box.depth = baseBox.depth
            let accentY = baseBox.height + extraTop + accentBox.depth
            box.draw = { ctx in
                baseBox.draw(ctx)
                ctx.saveGState(); ctx.translateBy(x: 0, y: accentY); accentBox.draw(ctx); ctx.restoreGState()
            }
        }
        return box
    }

    // MARK: Matrices

    private static func layoutMatrix(_ kind: MatrixKind, _ rows: [[[MathNode]]], context: MathContext, variant: MathVariant) -> MBox {
        let fontSize = context.fontSize
        let cellStyle: MathStyle = context.style == .display ? .text : context.style
        let cellContext = context.styled(cellStyle)
        let cellBoxes: [[MBox]] = rows.map { row in row.map { hlist($0, cellContext, variant: variant) } }

        let columns = cellBoxes.map(\.count).max() ?? 0
        var colWidths = [CGFloat](repeating: 0, count: columns)
        for row in cellBoxes { for (c, box) in row.enumerated() { colWidths[c] = max(colWidths[c], box.width) } }

        let colGap = fontSize * (kind == .cases ? 0.6 : 1.0)
        let rowGap = fontSize * 0.5
        let rowHeights: [(h: CGFloat, d: CGFloat)] = cellBoxes.map { row in
            (row.map(\.height).max() ?? fontSize * 0.5, row.map(\.depth).max() ?? 0)
        }
        let rowCount = rowHeights.count
        let contentHeight = rowHeights.reduce(0) { $0 + $1.h + $1.d } + rowGap * CGFloat(max(rowCount - 1, 0))

        var baselineY: [CGFloat] = []
        var cursor = contentHeight / 2
        for (idx, (h, d)) in rowHeights.enumerated() {
            cursor -= h
            baselineY.append(cursor)
            cursor -= d
            if idx < rowCount - 1 { cursor -= rowGap }
        }

        var colX: [CGFloat] = []
        var x: CGFloat = 0
        for c in 0..<columns { colX.append(x); x += colWidths[c] + colGap }

        var box = MBox()
        box.width = max(x - colGap, 0)
        box.height = contentHeight / 2
        box.depth = contentHeight / 2
        box.draw = { ctx in
            for (r, row) in cellBoxes.enumerated() {
                let y = baselineY[r]
                for (c, cellBox) in row.enumerated() {
                    let slot = colWidths[c]
                    let dx: CGFloat
                    switch kind.alignment(column: c) {
                    case .left: dx = 0
                    case .center: dx = (slot - cellBox.width) / 2
                    case .right: dx = slot - cellBox.width
                    }
                    ctx.saveGState()
                    ctx.translateBy(x: colX[c] + dx, y: y)
                    cellBox.draw(ctx)
                    ctx.restoreGState()
                }
            }
        }

        if let (left, right) = kind.delimiters {
            return layoutDelimited(left: left, right: right, inner: box, context: context)
        }
        return box
    }
}
