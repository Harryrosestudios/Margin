import Foundation

enum MatrixKind {
    case matrix, pmatrix, bmatrix, bMatrix, vmatrix, vMatrix, cases, aligned, gathered

    init?(latexName: String) {
        switch latexName {
        case "matrix": self = .matrix
        case "pmatrix": self = .pmatrix
        case "bmatrix": self = .bmatrix
        case "Bmatrix": self = .bMatrix
        case "vmatrix": self = .vmatrix
        case "Vmatrix": self = .vMatrix
        case "cases": self = .cases
        case "aligned", "align", "align*", "eqnarray", "eqnarray*": self = .aligned
        case "gathered", "gather", "gather*", "multline", "multline*": self = .gathered
        default: return nil
        }
    }

    /// Left/right delimiter glyphs drawn around the whole matrix, if any.
    var delimiters: (String, String)? {
        switch self {
        case .pmatrix: return ("(", ")")
        case .bmatrix: return ("[", "]")
        case .bMatrix: return ("{", "}")
        case .vmatrix: return ("|", "|")
        case .vMatrix: return ("‖", "‖")
        case .cases: return ("{", "")
        default: return nil
        }
    }

    /// How each column aligns. `.aligned` alternates right/left (the usual
    /// "expr =" / "value" pattern); everything else is uniform.
    func alignment(column: Int) -> MColumnAlign {
        switch self {
        case .cases: return .left
        case .gathered: return .center
        case .aligned: return column % 2 == 0 ? .right : .left
        default: return .center
        }
    }
}

enum MColumnAlign { case left, center, right }

indirect enum MathNode {
    case letter(Character)
    case symbol(String, AtomClass, upright: Bool, limits: Bool)
    case text(String)
    case group([MathNode])
    case styled(MathVariant, [MathNode])
    case frac(num: [MathNode], den: [MathNode], rule: Bool, left: String?, right: String?)
    case sqrt(index: [MathNode]?, radicand: [MathNode])
    case scripts(base: MathNode, sub: [MathNode]?, sup: [MathNode]?, limits: Bool?)
    case delimited(left: String, body: [MathNode], right: String)
    case accent(String, [MathNode])
    case spacing(CGFloat)
    case matrix(MatrixKind, [[[MathNode]]])
    case error(String)
}

struct MathParseError: Error {}

struct MathParser {
    private let chars: [Character]
    private var i = 0

    init(_ s: String) { chars = Array(s) }

    private var current: Character? { i < chars.count ? chars[i] : nil }

    private mutating func skipSpace() {
        while let c = current, c == " " || c == "\n" || c == "\t" { i += 1 }
    }

    mutating func expectEnd() throws {
        skipSpace()
        if current != nil { throw MathParseError() }
    }

    /// A control word ahead (without consuming), used to let the caller decide
    /// whether `\end`/`\right` closes the list it is building.
    private func peekControlWord() -> String? {
        guard current == "\\" else { return nil }
        var j = i + 1
        guard j < chars.count, chars[j].isLetter else { return nil }
        var word = ""
        while j < chars.count, chars[j].isLetter { word.append(chars[j]); j += 1 }
        return word
    }

    mutating func parseList(stopAmp: Bool = false, stopRow: Bool = false, stopBracket: Bool = false) throws -> [MathNode] {
        var nodes: [MathNode] = []
        while true {
            skipSpace()
            guard let c = current else { break }
            if c == "}" { break }
            if stopBracket, c == "]" { break }
            if stopAmp, c == "&" { break }
            if stopRow, c == "\\", i + 1 < chars.count, chars[i + 1] == "\\" { break }
            if c == "\\", let word = peekControlWord(), word == "end" || word == "right" { break }
            let atom = try parseAtom()
            nodes.append(try attachScripts(atom))
        }
        return nodes
    }

    // MARK: Atoms

    private mutating func parseAtom() throws -> MathNode {
        skipSpace()
        guard let c = current else { throw MathParseError() }

        if c == "{" {
            i += 1
            let nodes = try parseList()
            guard current == "}" else { throw MathParseError() }
            i += 1
            return .group(nodes)
        }
        if c == "\\" { return try parseCommand() }
        if c.isLetter {
            i += 1
            return .letter(c)
        }
        if c.isNumber {
            i += 1
            return .letter(c)
        }
        i += 1
        if let cls = MathSymbols.classOf(ascii: c) {
            return .symbol(String(c), cls, upright: false, limits: false)
        }
        switch c {
        case "'": return .symbol("′", .ord, upright: false, limits: false)
        case "~": return .spacing(0.25)
        default: return .symbol(String(c), .ord, upright: false, limits: false)
        }
    }

    /// Reads any trailing `^`/`_` (in either order) and `\limits`/`\nolimits` onto `base`.
    private mutating func attachScripts(_ base: MathNode) throws -> MathNode {
        var sub: [MathNode]?
        var sup: [MathNode]?
        var limits: Bool?
        while true {
            skipSpace()
            if current == "\\", let word = peekControlWord(), word == "limits" || word == "nolimits" {
                i += 1 + word.count
                limits = word == "limits"
                continue
            }
            guard let c = current else { break }
            if c == "^" { i += 1; sup = try parseScriptArgument(); continue }
            if c == "_" { i += 1; sub = try parseScriptArgument(); continue }
            break
        }
        guard sub != nil || sup != nil || limits != nil else { return base }
        return .scripts(base: base, sub: sub, sup: sup, limits: limits)
    }

    private mutating func parseScriptArgument() throws -> [MathNode] {
        skipSpace()
        if current == "{" {
            i += 1
            let nodes = try parseList()
            guard current == "}" else { throw MathParseError() }
            i += 1
            return nodes
        }
        return [try parseAtom()]
    }

    private mutating func parseGroup() throws -> [MathNode] {
        skipSpace()
        if current == "{" {
            i += 1
            let nodes = try parseList()
            guard current == "}" else { throw MathParseError() }
            i += 1
            return nodes
        }
        return [try parseAtom()]
    }

    // MARK: Commands

    private mutating func parseCommand() throws -> MathNode {
        i += 1
        guard let c = current else { throw MathParseError() }
        let name: String
        if c.isLetter {
            var word = ""
            while let c = current, c.isLetter { word.append(c); i += 1 }
            name = word
        } else {
            name = String(c)
            i += 1
        }

        switch name {
        case "frac", "dfrac", "tfrac":
            let num = try parseGroup(); let den = try parseGroup()
            return .frac(num: num, den: den, rule: true, left: nil, right: nil)
        case "binom", "dbinom", "tbinom":
            let num = try parseGroup(); let den = try parseGroup()
            return .frac(num: num, den: den, rule: false, left: "(", right: ")")
        case "sqrt":
            var index: [MathNode]?
            skipSpace()
            if current == "[" {
                i += 1
                index = try parseList(stopBracket: true)
                guard current == "]" else { throw MathParseError() }
                i += 1
            }
            return .sqrt(index: index, radicand: try parseGroup())
        case "left":
            let left = try readDelimiter()
            let body = try parseRemainingAfterLeft()
            let right = try readRightDelimiter()
            return .delimited(left: left, body: body, right: right)
        case "right":
            throw MathParseError()
        case "text", "mbox", "textrm", "textnormal":
            return .text(try readBraceText())
        case "operatorname":
            return .symbol(try readBraceText(), .op, upright: true, limits: false)
        case "mathrm": return .styled(.upright, try parseGroup())
        case "mathbf", "boldsymbol", "bm": return .styled(.bold, try parseGroup())
        case "mathit": return .styled(.italic, try parseGroup())
        case "mathbb": return .styled(.doubleStruck, try parseGroup())
        case "mathcal", "mathscr": return .styled(.script, try parseGroup())
        case "mathfrak": return .styled(.fraktur, try parseGroup())
        case "mathsf": return .styled(.sansSerif, try parseGroup())
        case "mathtt": return .styled(.monospace, try parseGroup())
        case "overline", "underline", "hat", "widehat", "tilde", "widetilde",
             "vec", "dot", "ddot", "breve", "check", "bar", "overbrace", "underbrace", "overrightarrow", "overleftarrow":
            return .accent(name, try parseGroup())
        case "begin":
            try expect("{")
            let envName = try readWord()
            try expect("}")
            guard let kind = MatrixKind(latexName: envName) else {
                try skipToEnd(envName)
                return .error("[\(envName)]")
            }
            return try parseMatrix(kind: kind, envName: envName)
        case ",": return .spacing(0.1667)
        case ":": return .spacing(0.2222)
        case ";": return .spacing(0.2778)
        case "!": return .spacing(-0.1667)
        case "quad": return .spacing(1.0)
        case "qquad": return .spacing(2.0)
        case " ", "\n": return .spacing(0.25)
        case "limits", "nolimits":
            return .group([])
        case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "nonumber", "notag":
            return .group([])
        default:
            if let symbol = MathSymbols.table[name] {
                return .symbol(symbol.glyph, symbol.atomClass, upright: symbol.upright, limits: symbol.defaultLimits)
            }
            return .error("\\" + name)
        }
    }

    /// `\left` was already consumed and its delimiter read; this reads the body up to the matching `\right`.
    private mutating func parseRemainingAfterLeft() throws -> [MathNode] {
        var nodes: [MathNode] = []
        while true {
            skipSpace()
            guard let c = current else { throw MathParseError() }
            if c == "\\", let word = peekControlWord(), word == "right" { break }
            let atom = try parseAtom()
            nodes.append(try attachScripts(atom))
        }
        return nodes
    }
    private mutating func readRightDelimiter() throws -> String {
        try expectControl("right")
        return try readDelimiter()
    }

    private mutating func readBraceText() throws -> String {
        skipSpace()
        guard current == "{" else { throw MathParseError() }
        i += 1
        var depth = 1
        var out = ""
        while let c = current {
            if c == "{" { depth += 1; out.append(c); i += 1; continue }
            if c == "}" {
                depth -= 1; i += 1
                if depth == 0 { return out }
                out.append(c); continue
            }
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "{" || n == "}" || n == "\\" || n == "$" || n == "%" || n == "&" { out.append(n); i += 2; continue }
            }
            out.append(c); i += 1
        }
        throw MathParseError()
    }

    private mutating func readDelimiter() throws -> String {
        skipSpace()
        guard let c = current else { throw MathParseError() }
        if c == "\\" {
            i += 1
            guard let c2 = current else { throw MathParseError() }
            let name: String
            if c2.isLetter {
                var w = ""
                while let c = current, c.isLetter { w.append(c); i += 1 }
                name = w
            } else {
                name = String(c2); i += 1
            }
            switch name {
            case "{": return "{"
            case "}": return "}"
            case "|": return "‖"
            case "lbrace": return "{"
            case "rbrace": return "}"
            case "langle": return "⟨"
            case "rangle": return "⟩"
            case "lceil": return "⌈"
            case "rceil": return "⌉"
            case "lfloor": return "⌊"
            case "rfloor": return "⌋"
            case "vert": return "|"
            case "Vert": return "‖"
            default: return ""
            }
        }
        i += 1
        if c == "." { return "" }
        return String(c)
    }

    private mutating func expect(_ ch: Character) throws {
        skipSpace()
        guard current == ch else { throw MathParseError() }
        i += 1
    }

    private mutating func expectControl(_ word: String) throws {
        skipSpace()
        guard current == "\\" else { throw MathParseError() }
        i += 1
        let got = try readWord()
        guard got == word else { throw MathParseError() }
    }

    private mutating func readWord() throws -> String {
        var w = ""
        while let c = current, c.isLetter || c == "*" { w.append(c); i += 1 }
        guard !w.isEmpty else { throw MathParseError() }
        return w
    }

    private mutating func skipToEnd(_ name: String) throws {
        let needle = Array("\\end{\(name)}")
        while i < chars.count {
            if i + needle.count <= chars.count, Array(chars[i..<(i + needle.count)]) == needle {
                i += needle.count
                return
            }
            i += 1
        }
    }

    // MARK: Matrices

    private mutating func parseMatrix(kind: MatrixKind, envName: String) throws -> MathNode {
        var rows: [[[MathNode]]] = [[]]
        while true {
            let cell = try parseList(stopAmp: true, stopRow: true)
            rows[rows.count - 1].append(cell)
            skipSpace()
            if current == "&" { i += 1; continue }
            if current == "\\", i + 1 < chars.count, chars[i + 1] == "\\" {
                i += 2
                skipSpace()
                if current == "[" { while let c = current, c != "]" { i += 1 }; if current == "]" { i += 1 } }
                rows.append([])
                continue
            }
            break
        }
        try expectControl("end")
        try expect("{")
        let closing = try readWord()
        try expect("}")
        guard closing == envName else { throw MathParseError() }

        if let last = rows.last, last.count == 1, last[0].isEmpty, rows.count > 1 {
            rows.removeLast()
        }
        return .matrix(kind, rows)
    }
}
