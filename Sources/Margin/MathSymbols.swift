import Foundation

/// TeX's eight atom classes, used to decide inter-atom spacing (TeXbook
/// Appendix G) and to know whether an atom can take \limits.
enum AtomClass {
    case ord, op, bin, rel, open, close, punct, inner
}

enum MathVariant {
    case italic, upright, bold, boldItalic, doubleStruck, script, fraktur, monospace, sansSerif
}

enum MathAlphabet {
    private struct Block {
        let upperBase: UInt32
        let lowerBase: UInt32
        let digitBase: UInt32?
        let upperHoles: [Character: UInt32]
        let lowerHoles: [Character: UInt32]
    }

    private static let blocks: [MathVariant: Block] = [
        .bold: Block(upperBase: 0x1D400, lowerBase: 0x1D41A, digitBase: 0x1D7CE, upperHoles: [:], lowerHoles: [:]),
        .italic: Block(upperBase: 0x1D434, lowerBase: 0x1D44E, digitBase: nil, upperHoles: [:], lowerHoles: ["h": 0x210E]),
        .boldItalic: Block(upperBase: 0x1D468, lowerBase: 0x1D482, digitBase: nil, upperHoles: [:], lowerHoles: [:]),
        .script: Block(
            upperBase: 0x1D49C, lowerBase: 0x1D4B6, digitBase: nil,
            upperHoles: ["B": 0x212C, "E": 0x2130, "F": 0x2131, "H": 0x210B, "I": 0x2110, "L": 0x2112, "M": 0x2133, "R": 0x211B],
            lowerHoles: ["e": 0x212F, "g": 0x210A, "o": 0x2134]
        ),
        .fraktur: Block(
            upperBase: 0x1D504, lowerBase: 0x1D51E, digitBase: nil,
            upperHoles: ["C": 0x212D, "H": 0x210C, "I": 0x2111, "R": 0x211C, "Z": 0x2128],
            lowerHoles: [:]
        ),
        .doubleStruck: Block(
            upperBase: 0x1D538, lowerBase: 0x1D552, digitBase: 0x1D7D8,
            upperHoles: ["C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119, "Q": 0x211A, "R": 0x211D, "Z": 0x2124],
            lowerHoles: [:]
        ),
        .monospace: Block(upperBase: 0x1D670, lowerBase: 0x1D68A, digitBase: 0x1D7F6, upperHoles: [:], lowerHoles: [:]),
        .sansSerif: Block(upperBase: 0x1D5A0, lowerBase: 0x1D5BA, digitBase: 0x1D7E2, upperHoles: [:], lowerHoles: [:]),
    ]

    /// Maps plain ASCII letters/digits onto the Mathematical Alphanumeric
    /// Symbols plane for the given variant. `.upright` is the identity (plain
    /// Latin letters already look upright outside the italic range).
    static func transform(_ s: String, variant: MathVariant) -> String {
        guard variant != .upright, let block = blocks[variant] else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c >= "A", c <= "Z" {
                let value = block.upperHoles[c] ?? (block.upperBase + (c.asciiValue.map(UInt32.init)! - 0x41))
                out.unicodeScalars.append(Unicode.Scalar(value)!)
            } else if c >= "a", c <= "z" {
                let value = block.lowerHoles[c] ?? (block.lowerBase + (c.asciiValue.map(UInt32.init)! - 0x61))
                out.unicodeScalars.append(Unicode.Scalar(value)!)
            } else if c >= "0", c <= "9", let digitBase = block.digitBase {
                out.unicodeScalars.append(Unicode.Scalar(digitBase + (c.asciiValue.map(UInt32.init)! - 0x30))!)
            } else {
                out.append(c)
            }
        }
        return out
    }
}

struct MathSymbol {
    var glyph: String
    var atomClass: AtomClass
    /// Operators (\sum, \lim, ...) that default to stacked limits in display style.
    var defaultLimits: Bool = false
    /// Rendered in the upright text font rather than the math font (operator names).
    var upright: Bool = false
}

enum MathSymbols {
    /// Command name (without the backslash) -> symbol. Single, non-letter
    /// command characters (\,  \{  \&  ...) are looked up the same way.
    static let table: [String: MathSymbol] = {
        var t: [String: MathSymbol] = [:]
        func ord(_ names: [String], _ glyph: String) { for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .ord) } }
        func bin(_ names: [String], _ glyph: String) { for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .bin) } }
        func rel(_ names: [String], _ glyph: String) { for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .rel) } }
        func open(_ names: [String], _ glyph: String) { for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .open) } }
        func close(_ names: [String], _ glyph: String) { for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .close) } }
        func punct(_ names: [String], _ glyph: String) { for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .punct) } }
        func op(_ names: [String], _ glyph: String, limits: Bool = false) {
            for n in names { t[n] = MathSymbol(glyph: glyph, atomClass: .op, defaultLimits: limits) }
        }
        func opName(_ names: [String], limits: Bool = false) {
            for n in names { t[n] = MathSymbol(glyph: n, atomClass: .op, defaultLimits: limits, upright: true) }
        }

        // Greek
        ord(["alpha"], "α"); ord(["beta"], "β"); ord(["gamma"], "γ"); ord(["delta"], "δ")
        ord(["epsilon"], "ϵ"); ord(["varepsilon"], "ε"); ord(["zeta"], "ζ"); ord(["eta"], "η")
        ord(["theta"], "θ"); ord(["vartheta"], "ϑ"); ord(["iota"], "ι"); ord(["kappa"], "κ")
        ord(["lambda"], "λ"); ord(["mu"], "μ"); ord(["nu"], "ν"); ord(["xi"], "ξ")
        ord(["pi"], "π"); ord(["varpi"], "ϖ"); ord(["rho"], "ρ"); ord(["varrho"], "ϱ")
        ord(["sigma"], "σ"); ord(["varsigma"], "ς"); ord(["tau"], "τ"); ord(["upsilon"], "υ")
        ord(["phi"], "ϕ"); ord(["varphi"], "φ"); ord(["chi"], "χ"); ord(["psi"], "ψ"); ord(["omega"], "ω")
        ord(["Gamma"], "Γ"); ord(["Delta"], "Δ"); ord(["Theta"], "Θ"); ord(["Lambda"], "Λ")
        ord(["Xi"], "Ξ"); ord(["Pi"], "Π"); ord(["Sigma"], "Σ"); ord(["Upsilon"], "Υ")
        ord(["Phi"], "Φ"); ord(["Psi"], "Ψ"); ord(["Omega"], "Ω")
        ord(["digamma"], "ϝ"); ord(["nabla"], "∇"); ord(["partial"], "∂")

        // Big operators
        op(["sum"], "∑", limits: true); op(["prod"], "∏", limits: true); op(["coprod"], "∐", limits: true)
        op(["int"], "∫"); op(["oint"], "∮"); op(["iint"], "∬"); op(["iiint"], "∭")
        op(["bigcup"], "⋃", limits: true); op(["bigcap"], "⋂", limits: true)
        op(["bigvee"], "⋁", limits: true); op(["bigwedge"], "⋀", limits: true)
        op(["bigoplus"], "⨁", limits: true); op(["bigotimes"], "⨂", limits: true)
        op(["bigodot"], "⨀", limits: true); op(["biguplus"], "⨄", limits: true); op(["bigsqcup"], "⨆", limits: true)
        opName(["lim", "limsup", "liminf", "max", "min", "sup", "inf", "det", "gcd", "Pr"], limits: true)
        opName(["sin", "cos", "tan", "sec", "csc", "cot", "sinh", "cosh", "tanh", "coth",
                "arcsin", "arccos", "arctan", "log", "ln", "exp", "arg", "deg", "hom", "ker", "dim"])

        // Binary operators
        bin(["pm"], "±"); bin(["mp"], "∓"); bin(["times"], "×"); bin(["div"], "÷")
        bin(["cdot", "cdotp"], "·"); bin(["ast"], "∗"); bin(["star"], "⋆"); bin(["circ"], "∘")
        bin(["bullet"], "∙"); bin(["oplus"], "⊕"); bin(["ominus"], "⊖"); bin(["otimes"], "⊗")
        bin(["oslash"], "⊘"); bin(["odot"], "⊙"); bin(["wedge", "land"], "∧"); bin(["vee", "lor"], "∨")
        bin(["cap"], "∩"); bin(["cup"], "∪"); bin(["setminus"], "∖"); bin(["wr"], "≀")
        bin(["diamond"], "⋄"); bin(["triangleleft"], "◁"); bin(["triangleright"], "▷")
        bin(["lhd"], "⊲"); bin(["rhd"], "⊳"); bin(["amalg"], "⨿")
        bin(["dagger"], "†"); bin(["ddagger"], "‡"); bin(["uplus"], "⊎")
        bin(["sqcap"], "⊓"); bin(["sqcup"], "⊔"); bin(["bigtriangleup"], "△"); bin(["bigtriangledown"], "▽")

        // Relations
        rel(["neq", "ne"], "≠"); rel(["leq", "le"], "≤"); rel(["geq", "ge"], "≥")
        rel(["ll"], "≪"); rel(["gg"], "≫"); rel(["equiv"], "≡"); rel(["sim"], "∼")
        rel(["simeq"], "≃"); rel(["approx"], "≈"); rel(["cong"], "≅"); rel(["propto"], "∝")
        rel(["parallel"], "∥"); rel(["nparallel"], "∦"); rel(["perp"], "⊥")
        rel(["in"], "∈"); rel(["notin"], "∉"); rel(["ni"], "∋")
        rel(["subset"], "⊂"); rel(["supset"], "⊃"); rel(["subseteq"], "⊆"); rel(["supseteq"], "⊇")
        rel(["subsetneq"], "⊊"); rel(["supsetneq"], "⊋")
        rel(["sqsubseteq"], "⊑"); rel(["sqsupseteq"], "⊒")
        rel(["models"], "⊨"); rel(["vdash"], "⊢"); rel(["dashv"], "⊣")
        rel(["asymp"], "≍"); rel(["bowtie"], "⋈"); rel(["smile"], "⌣"); rel(["frown"], "⌢")
        rel(["doteq"], "≐"); rel(["prec"], "≺"); rel(["succ"], "≻")
        rel(["preceq"], "⪯"); rel(["succeq"], "⪰"); rel(["mid"], "∣"); rel(["nmid"], "∤")
        rel(["triangleq"], "≜")

        // Arrows
        rel(["rightarrow", "to"], "→"); rel(["leftarrow", "gets"], "←"); rel(["leftrightarrow"], "↔")
        rel(["Rightarrow"], "⇒"); rel(["Leftarrow"], "⇐"); rel(["Leftrightarrow"], "⇔")
        rel(["longrightarrow"], "⟶"); rel(["longleftarrow"], "⟵"); rel(["longleftrightarrow"], "⟷")
        rel(["Longrightarrow"], "⟹"); rel(["Longleftarrow"], "⟸"); rel(["Longleftrightarrow"], "⟺")
        rel(["mapsto"], "↦"); rel(["longmapsto"], "⟼")
        rel(["hookrightarrow"], "↪"); rel(["hookleftarrow"], "↩")
        rel(["nearrow"], "↗"); rel(["searrow"], "↘"); rel(["swarrow"], "↙"); rel(["nwarrow"], "↖")
        ord(["uparrow"], "↑"); ord(["downarrow"], "↓"); ord(["updownarrow"], "↕")
        ord(["Uparrow"], "⇑"); ord(["Downarrow"], "⇓"); ord(["Updownarrow"], "⇕")
        rel(["rightharpoonup"], "⇀"); rel(["leftharpoonup"], "↼")

        // Misc ord
        ord(["infty"], "∞"); ord(["forall"], "∀"); ord(["exists"], "∃"); ord(["nexists"], "∄")
        ord(["emptyset"], "∅"); ord(["varnothing"], "∅")
        ord(["aleph"], "ℵ"); ord(["hbar"], "ℏ"); ord(["ell"], "ℓ"); ord(["wp"], "℘")
        ord(["Re"], "ℜ"); ord(["Im"], "ℑ"); ord(["angle"], "∠"); ord(["triangle"], "△")
        ord(["square"], "□"); ord(["Box"], "□"); ord(["diamondsuit"], "♢")
        ord(["top"], "⊤"); ord(["bot"], "⊥"); ord(["neg", "lnot"], "¬")
        ord(["flat"], "♭"); ord(["sharp"], "♯"); ord(["natural"], "♮")
        ord(["prime"], "′"); ord(["backslash"], "\\"); ord(["degree"], "°")
        punct(["ldots", "dots", "dotsc", "dotsb"], "…"); ord(["cdots"], "⋯")
        ord(["vdots"], "⋮"); ord(["ddots"], "⋱")
        ord(["%"], "%"); ord(["&"], "&"); ord(["#"], "#"); ord(["_"], "_")

        // Delimiters (the ASCII ones are handled directly by the parser; these
        // cover the named \commands for the same or related glyphs)
        open(["{", "lbrace"], "{"); close(["}", "rbrace"], "}")
        ord(["vert"], "|"); ord(["Vert", "lVert", "rVert"], "‖")
        open(["langle"], "⟨"); close(["rangle"], "⟩")
        open(["lceil"], "⌈"); close(["rceil"], "⌉")
        open(["lfloor"], "⌊"); close(["rfloor"], "⌋")
        open(["lbrack"], "["); close(["rbrack"], "]")

        // Punctuation
        punct([","], ","); punct([";"], ";"); ord([":"], ":"); ord(["."], ".")

        return t
    }()

    /// How far an atom's class should default when `.` / `(` / `-` etc. are typed directly.
    static func classOf(ascii c: Character) -> AtomClass? {
        switch c {
        case "+", "-", "*": return .bin
        case "=", "<", ">": return .rel
        case "(", "[": return .open
        case ")", "]": return .close
        case ",", ";": return .punct
        default: return nil
        }
    }
}
