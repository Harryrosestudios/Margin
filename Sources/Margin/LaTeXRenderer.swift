import AppKit

/// A "paper style" preview of a LaTeX document: not a compiler, just enough
/// understanding of common document structure, macros and math to produce a
/// readable, editable preview — the same spirit as `MarkdownRenderer`.
///
/// Known simplifications: `\def` only supports simple `#1…#9` parameter
/// patterns (no delimited arguments); a multi-line `align`/`gather` block is
/// laid out as a single image by `MathRenderer`, so only one equation number
/// is placed for the whole block; comments and macro expansion are not aware
/// of verbatim-like environments, so a macro name written inside one is
/// (rarely) still expanded.
enum LaTeXRenderer {
    static func render(_ source: String, baseURL: URL?) -> NSAttributedString {
        let engine = LaTeXEngine(baseURL: baseURL)
        return engine.run(source)
    }
}

// MARK: - Macros

private struct Macro {
    var params: Int
    var defaultFirst: String?
    var body: String
}

private struct TheoremKind {
    var displayName: String
    var counterKey: String
    var numbered = true
}

private struct Style {
    var bold = false
    var italic = false
    var mono = false
    var smallCaps = false
    var underline = false
    var size: CGFloat = 16
}

private struct PendingLabel {
    var name: String
}

// MARK: - Engine

private final class LaTeXEngine {
    let baseURL: URL?
    init(baseURL: URL?) { self.baseURL = baseURL }

    // Registries built while scanning.
    var macros: [String: Macro] = [:]
    var theorems: [String: TheoremKind] = [
        "theorem": TheoremKind(displayName: "Theorem", counterKey: "thm"),
        "lemma": TheoremKind(displayName: "Lemma", counterKey: "thm"),
        "proposition": TheoremKind(displayName: "Proposition", counterKey: "thm"),
        "corollary": TheoremKind(displayName: "Corollary", counterKey: "thm"),
        "definition": TheoremKind(displayName: "Definition", counterKey: "def"),
        "example": TheoremKind(displayName: "Example", counterKey: "def"),
        "remark": TheoremKind(displayName: "Remark", counterKey: "rem"),
        "claim": TheoremKind(displayName: "Claim", counterKey: "thm"),
    ]
    var titleText: String?
    var authorText: String?
    var dateText: String?

    var labels: [String: String] = [:]
    var bibIndex: [String: Int] = [:]
    var bibCount = 0
    var footnotes: [NSAttributedString] = []
    var bibliographyRendered = false

    var sectionCounters = [0, 0, 0]
    var appendixMode = false
    var equationCounter = 0
    var figureCounter = 0
    var tableCounter = 0
    var theoremCounters: [String: Int] = [:]
    var lastNumberContext: String?
    var listDepth = 0
    var listCounters: [Int] = []

    // Current scan buffer (the macro-expanded document body).
    var units: [unichar] = []
    var offsets: [Int] = []
    var i = 0

    let output = NSMutableAttributedString()
    var paragraph = NSMutableAttributedString()
    var paragraphIndented = true
    var lastWasDisplay = true
    var style = Style()
    var styleStack: [Style] = []

    // MARK: Entry point

    func run(_ source: String) -> NSAttributedString {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSAttributedString(string: "Empty document\n", attributes: [
                .font: MathFont.text(16), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
        let stripped = stripComments(source)
        let (preamble, body) = splitDocument(stripped)
        scanDirectives(preamble)
        scanDirectives(body)

        let (expanded, expandedOffsets) = expand(body)
        units = Array(expanded.utf16)
        offsets = expandedOffsets
        i = 0

        _ = parseInline(into: paragraph, stopBefore: ["end"])
        flushParagraph()

        if !footnotes.isEmpty { appendFootnotesSection() }
        resolvePendingRuns()
        if output.length == 0 {
            output.append(NSAttributedString(string: " \n", attributes: [.font: MathFont.text(16)]))
        }
        return output
    }

    // MARK: Low-level scanning helpers

    private func currentUnit() -> unichar? { i < units.count ? units[i] : nil }
    private func currentOffset() -> Int {
        if i < offsets.count, offsets[i] >= 0 { return offsets[i] }
        return nearestKnownOffset(before: i)
    }
    private func isLetterUnit(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

    private func peekControlWord() -> String? {
        guard currentUnit() == 0x5C else { return nil }
        var j = i + 1
        var w = ""
        while j < units.count, isLetterUnit(units[j]) { w.append(Character(UnicodeScalar(units[j])!)); j += 1 }
        return w
    }

    /// Consumes a backslash command: a run of letters, or (if none) one symbol character.
    private func readControlWord() -> String {
        i += 1
        var w = ""
        while let c = currentUnit(), isLetterUnit(c) { w.append(Character(UnicodeScalar(c)!)); i += 1 }
        if w.isEmpty, let c = currentUnit(), let scalar = Unicode.Scalar(c) {
            w = String(scalar)
            i += 1
        }
        return w
    }

    private func skipSpacesAndComments() {
        while let c = currentUnit(), c == 0x20 || c == 0x0A || c == 0x09 { i += 1 }
    }

    private func sliceRaw(_ a: Int, _ b: Int) -> String {
        guard b > a else { return "" }
        return String(utf16CodeUnits: Array(units[a..<b]), count: b - a)
    }

    @discardableResult
    private func readBraceGroupRaw() -> (text: String, startOffset: Int)? {
        skipSpacesAndComments()
        guard currentUnit() == 0x7B else { return nil }
        i += 1
        let startOffset = currentOffset()
        var depth = 1
        let start = i
        while let c = currentUnit(), depth > 0 {
            if c == 0x7B { depth += 1 } else if c == 0x7D { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        let text = sliceRaw(start, i)
        if currentUnit() != nil { i += 1 }
        return (text, startOffset)
    }

    private func readBracketGroupRaw() -> String? {
        skipSpacesAndComments()
        guard currentUnit() == 0x5B else { return nil }
        i += 1
        var depth = 1
        let start = i
        while let c = currentUnit(), depth > 0 {
            if c == 0x5B { depth += 1 } else if c == 0x5D { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        let text = sliceRaw(start, i)
        if currentUnit() != nil { i += 1 }
        return text
    }

    /// Scans raw source up to the matching `\end{name}` (assuming correct
    /// nesting), without descending into nested `\begin`/`\end` pairs of a
    /// different name — fine for our purposes since we only use this for
    /// verbatim-like content and math environments, which don't nest.
    private func readRawUntilEnd(_ name: String) -> String {
        let start = i
        while let c = currentUnit() {
            if c == 0x5C, peekControlWord() == "end" {
                let saved = i
                _ = readControlWord()
                if let (envName, _) = readBraceGroupRaw(), envName == name {
                    return sliceRaw(start, saved)
                }
                i = saved + 1
                continue
            }
            i += 1
        }
        return sliceRaw(start, units.count)
    }

    private func consumeEnd(_ expected: String) {
        skipSpacesAndComments()
        guard currentUnit() == 0x5C else { return }
        let saved = i
        guard readControlWord() == "end" else { i = saved; return }
        _ = readBraceGroupRaw()
    }

    private func nearestKnownOffset(before idx: Int) -> Int {
        var k = min(idx, offsets.count) - 1
        while k >= 0 { if offsets[k] >= 0 { return offsets[k] }; k -= 1 }
        return 0
    }

    private func isConsecutive(_ start: Int, _ end: Int) -> Bool {
        guard start < end, start < offsets.count, offsets[start] >= 0 else { return false }
        var expect = offsets[start]
        for k in start..<end {
            guard k < offsets.count, offsets[k] == expect else { return false }
            expect += 1
        }
        return true
    }

    /// Re-renders an out-of-band raw fragment (title page text, description
    /// term labels) with its own synthetic, offset-less scan state.
    private func renderFragment(_ raw: String, bold: Bool = false) -> NSAttributedString {
        let savedUnits = units, savedOffsets = offsets, savedI = i
        let expanded = expandPlain(raw, depth: 0)
        units = Array(expanded.utf16)
        offsets = Array(repeating: -1, count: units.count)
        i = 0
        styleStack.append(style)
        if bold { style.bold = true }
        let buffer = NSMutableAttributedString()
        _ = parseInline(into: buffer, stopBefore: ["end"])
        style = styleStack.removeLast()
        units = savedUnits; offsets = savedOffsets; i = savedI
        return buffer
    }

    /// Reads a live `{...}` argument, rendering its content (nested commands,
    /// math, ligatures all handled) rather than treating it as raw text.
    private func captureInline() -> NSMutableAttributedString {
        skipSpacesAndComments()
        let buffer = NSMutableAttributedString()
        guard currentUnit() == 0x7B else { return buffer }
        i += 1
        _ = parseInline(into: buffer, stopBrace: true)
        if currentUnit() == 0x7D { i += 1 }
        return buffer
    }

    private func fontFor(_ style: Style) -> NSFont {
        let size = style.smallCaps ? style.size * 0.84 : style.size
        if style.mono { return NSFont.monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular) }
        return MathFont.text(size, bold: style.bold, italic: style.italic)
    }

    private func transformLigatures(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "---", with: "\u{2014}")
        out = out.replacingOccurrences(of: "--", with: "\u{2013}")
        out = out.replacingOccurrences(of: "``", with: "\u{201C}")
        out = out.replacingOccurrences(of: "''", with: "\u{201D}")
        out = out.replacingOccurrences(of: "`", with: "\u{2018}")
        out = out.replacingOccurrences(of: "'", with: "\u{2019}")
        out = out.replacingOccurrences(of: "~", with: "\u{00A0}")
        return out
    }

    private static let accentTable: [String: [Character: Character]] = [
        "'": ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý",
              "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú", "Y": "Ý", "n": "ń", "c": "ć", "s": "ś", "z": "ź"],
        "`": ["a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù", "A": "À", "E": "È", "I": "Ì", "O": "Ò", "U": "Ù"],
        "^": ["a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û", "A": "Â", "E": "Ê", "I": "Î", "O": "Ô", "U": "Û"],
        "\"": ["a": "ä", "e": "ë", "i": "ï", "o": "ö", "u": "ü", "A": "Ä", "E": "Ë", "I": "Ï", "O": "Ö", "U": "Ü"],
        "~": ["a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"],
        "=": ["a": "ā", "e": "ē", "i": "ī", "o": "ō", "u": "ū"],
        ".": ["z": "ż", "Z": "Ż"],
        "c": ["c": "ç", "C": "Ç", "s": "ş", "S": "Ş"],
        "v": ["s": "š", "S": "Š", "c": "č", "C": "Č", "z": "ž", "Z": "Ž", "e": "ě", "r": "ř"],
        "H": ["o": "ő", "O": "Ő", "u": "ű", "U": "Ű"],
        "r": ["a": "å", "A": "Å", "u": "ů"],
        "k": ["a": "ą", "A": "Ą", "e": "ę", "E": "Ę"],
    ]
    private func accentedChar(_ command: String, _ base: Character) -> Character {
        Self.accentTable[command]?[base] ?? base
    }
    private func readAccentedChar(command: String) -> Character {
        skipSpacesAndComments()
        var base: Character = " "
        if currentUnit() == 0x7B {
            if let (raw, _) = readBraceGroupRaw(), let first = raw.first { base = first }
        } else if let c = currentUnit(), let scalar = Unicode.Scalar(c) {
            base = Character(scalar)
            i += 1
        }
        return accentedChar(command, base)
    }

    private func alpha(_ n: Int) -> String {
        guard n >= 1, n <= 26 else { return "\(n)" }
        return String(UnicodeScalar(96 + n)!)
    }
    private func roman(_ n: Int) -> String {
        guard n >= 1, n <= 3999 else { return "\(n)" }
        let values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
        let symbols = ["m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"]
        var n = n
        var out = ""
        for (idx, value) in values.enumerated() {
            while n >= value { out += symbols[idx]; n -= value }
        }
        return out
    }

    // MARK: Inline scanning

    private enum StopReason: Equatable { case eof, closeBrace, amp, rowBreak, command(String) }

    @discardableResult
    /// `target` is captured once per call, but at the *top level* `self.paragraph`
    /// gets reassigned to a fresh instance every time it's flushed (see
    /// `flushParagraph`) — including by a block-level command handled partway
    /// through this very call (`\maketitle`, `\section`, `\begin{...}`, ...).
    /// A plain `target` parameter would then go stale for the rest of the
    /// loop, silently orphaning everything scanned afterwards. `isTopLevelCall`
    /// freezes *whether* this call started out writing to the top-level
    /// paragraph; `dest()` re-reads `self.paragraph` fresh on every use so it
    /// always finds wherever that paragraph currently is.
    private func parseInline(
        into target: NSMutableAttributedString,
        stopBrace: Bool = false, stopAmp: Bool = false, stopRow: Bool = false, stopBefore: Set<String> = []
    ) -> StopReason {
        let isTopLevelCall = target === paragraph
        func dest() -> NSMutableAttributedString { isTopLevelCall ? paragraph : target }

        var runStart = i
        func flushRun(_ end: Int) {
            guard end > runStart else { return }
            appendStyledRun(sliceRaw(runStart, end), from: runStart, to: end, into: dest())
        }
        while true {
            guard let c = currentUnit() else { flushRun(i); return .eof }
            if stopBrace, c == 0x7D { flushRun(i); return .closeBrace }
            if stopAmp, c == 0x26 { flushRun(i); return .amp }
            if stopRow, c == 0x5C, i + 1 < units.count, units[i + 1] == 0x5C { flushRun(i); return .rowBreak }
            if c == 0x5C, let word = peekControlWord(), stopBefore.contains(word) { flushRun(i); return .command(word) }

            if c == 0x24 {
                flushRun(i)
                emitMathSpan(target: dest())
                runStart = i
                continue
            }
            if c == 0x5C {
                flushRun(i)
                handleCommand(target: dest())
                runStart = i
                continue
            }
            if c == 0x7B {
                flushRun(i)
                i += 1
                styleStack.append(style)
                _ = parseInline(into: dest(), stopBrace: true)
                if currentUnit() == 0x7D { i += 1 }
                style = styleStack.removeLast()
                runStart = i
                continue
            }
            if isTopLevelCall, c == 0x0A, i + 1 < units.count, units[i + 1] == 0x0A {
                flushRun(i)
                i += 1
                while currentUnit() == 0x0A { i += 1 }
                flushParagraph()
                runStart = i
                continue
            }
            i += 1
        }
    }

    private func appendStyledRun(_ raw: String, from startIdx: Int, to endIdx: Int, into target: NSMutableAttributedString) {
        guard !raw.isEmpty else { return }
        var transformed = transformLigatures(raw)
        if style.smallCaps { transformed = transformed.uppercased() }
        var attrs: [NSAttributedString.Key: Any] = [.font: fontFor(style), .foregroundColor: NSColor.labelColor]
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if transformed == raw, isConsecutive(startIdx, endIdx) {
            attrs[.marginSource] = offsets[startIdx]
        } else {
            attrs[.marginAnchor] = startIdx < offsets.count && offsets[startIdx] >= 0 ? offsets[startIdx] : nearestKnownOffset(before: startIdx)
        }
        target.append(NSAttributedString(string: transformed, attributes: attrs))
    }

    private func appendLiteral(_ s: String, target: NSMutableAttributedString) {
        var attrs: [NSAttributedString.Key: Any] = [.font: fontFor(style), .foregroundColor: NSColor.labelColor]
        attrs[.marginAnchor] = currentOffset()
        target.append(NSAttributedString(string: s, attributes: attrs))
    }

    private func wrapStyle(target: NSMutableAttributedString, _ mutate: (inout Style) -> Void) {
        skipSpacesAndComments()
        guard currentUnit() == 0x7B else { return }
        i += 1
        styleStack.append(style)
        mutate(&style)
        _ = parseInline(into: target, stopBrace: true)
        if currentUnit() == 0x7D { i += 1 }
        style = styleStack.removeLast()
    }

    /// Applies `pstyle` only to ranges of `text` that don't already carry a
    /// paragraph style of their own — e.g. a centered display-math paragraph
    /// embedded partway through a theorem body or list item. A plain blanket
    /// `addAttribute` would stomp over that per-range style.
    private func applyDefaultParagraphStyle(_ pstyle: NSParagraphStyle, to text: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: text.length)
        var covered: [NSRange] = []
        text.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            if value != nil { covered.append(range) }
        }
        var cursor = 0
        for range in covered.sorted(by: { $0.location < $1.location }) {
            if range.location > cursor {
                text.addAttribute(.paragraphStyle, value: pstyle, range: NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < full.length {
            text.addAttribute(.paragraphStyle, value: pstyle, range: NSRange(location: cursor, length: full.length - cursor))
        }
    }

    /// Drops a trailing run of plain whitespace/newlines (left over from
    /// source text like "...QED.\n" right before `\end{proof}`) so a mark
    /// appended right after — the ∎, say — lands on the same visual line.
    private func trimTrailingWhitespace(_ text: NSMutableAttributedString) {
        var length = text.length
        let string = text.string as NSString
        while length > 0 {
            let c = string.character(at: length - 1)
            guard c == 0x20 || c == 0x0A || c == 0x09 else { break }
            length -= 1
        }
        if length < text.length {
            text.deleteCharacters(in: NSRange(location: length, length: text.length - length))
        }
    }

    // MARK: Math spans

    private func emitMathSpan(target: NSMutableAttributedString) {
        let startOffset = currentOffset()
        i += 1
        var display = false
        if currentUnit() == 0x24 { display = true; i += 1 }
        let contentStart = i
        while let c = currentUnit() {
            if c == 0x24 {
                if !display { break }
                if i + 1 < units.count, units[i + 1] == 0x24 { break }
            }
            i += 1
        }
        let raw = sliceRaw(contentStart, i)
        i = min(i + (display ? 2 : 1), units.count)
        insertMath(raw, display: display, target: target, sourceOffset: startOffset)
    }

    /// Display math (`$$...$$`, `\[...\]`) always stays inside `target` — the
    /// same buffer surrounding text is accumulating in, whatever that buffer
    /// is — rather than jumping straight to `output`. Jumping to `output`
    /// used to put it out of order whenever it occurred inside a theorem,
    /// abstract, quote, list item, table cell or caption, all of which only
    /// append their buffer to `output` once they're done. Centering survives
    /// the block's own final paragraph-style pass via `applyDefaultParagraphStyle`.
    private func insertMath(_ raw: String, display: Bool, target: NSMutableAttributedString, sourceOffset: Int) {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let attributed = MathRenderer.render(raw, fontSize: display ? 18 : 16, display: display)
        if display {
            let line = NSMutableAttributedString(attributedString: attributed)
            line.addAttribute(.marginAnchor, value: sourceOffset, range: NSRange(location: 0, length: line.length))
            let pstyle = NSMutableParagraphStyle()
            pstyle.alignment = .center
            pstyle.paragraphSpacing = 14
            pstyle.paragraphSpacingBefore = 10
            if target.length > 0, !target.string.hasSuffix("\n") {
                target.append(NSAttributedString(string: "\n"))
            }
            let insertedAt = target.length
            target.append(line)
            target.append(NSAttributedString(string: "\n"))
            target.addAttribute(.paragraphStyle, value: pstyle, range: NSRange(location: insertedAt, length: target.length - insertedAt))
            lastWasDisplay = true
            paragraphIndented = false
        } else {
            let run = NSMutableAttributedString(attributedString: attributed)
            run.addAttribute(.marginAnchor, value: sourceOffset, range: NSRange(location: 0, length: run.length))
            target.append(run)
        }
    }

    private func emitDisplayMathEnvironment(_ name: String) {
        let starred = name.hasSuffix("*")
        let base = starred ? String(name.dropLast()) : name
        let startOffset = currentOffset()
        var raw = readRawUntilEnd(name)

        var label: String?
        if let range = raw.range(of: "\\label{"), let closeRange = raw.range(of: "}", range: range.upperBound..<raw.endIndex) {
            label = String(raw[range.upperBound..<closeRange.lowerBound])
            raw.removeSubrange(range.lowerBound..<closeRange.upperBound)
        }
        let mathSource: String
        switch base {
        case "align", "eqnarray": mathSource = "\\begin{aligned}\(raw)\\end{aligned}"
        case "gather", "multline": mathSource = "\\begin{gathered}\(raw)\\end{gathered}"
        default: mathSource = raw
        }
        flushParagraph()
        let attributed = MathRenderer.render(mathSource, fontSize: 18, display: true)
        let line = NSMutableAttributedString(attributedString: attributed)

        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = .center
        pstyle.paragraphSpacing = 14
        pstyle.paragraphSpacingBefore = 10
        if !starred, base != "displaymath" {
            equationCounter += 1
            lastNumberContext = "(\(equationCounter))"
            if let label { labels[label] = "(\(equationCounter))" }
            pstyle.tabStops = [NSTextTab(textAlignment: .right, location: 620)]
            line.append(NSAttributedString(string: "\t(\(equationCounter))", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        line.addAttribute(.marginAnchor, value: startOffset, range: NSRange(location: 0, length: line.length))
        line.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: line)
        output.append(line)
        lastWasDisplay = true
        paragraphIndented = false
    }

    // MARK: Comments

    private func stripComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var escaped = false
        var inComment = false
        for c in source {
            if inComment {
                if c == "\n" { inComment = false; out.append(c) }
                continue
            }
            if c == "\\", !escaped { escaped = true; out.append(c); continue }
            if c == "%", !escaped { inComment = true; continue }
            escaped = false
            out.append(c)
        }
        return out
    }

    // MARK: Preamble / body split

    private func splitDocument(_ source: String) -> (preamble: String, body: String) {
        guard let beginRange = source.range(of: "\\begin{document}") else { return ("", source) }
        let preamble = String(source[source.startIndex..<beginRange.lowerBound])
        var body = String(source[beginRange.upperBound...])
        if let endRange = body.range(of: "\\end{document}") {
            body = String(body[body.startIndex..<endRange.lowerBound])
        }
        return (preamble, body)
    }

    // MARK: Directive scanning (macros, theorems, title page)

    private func scanDirectives(_ text: String) {
        let u = Array(text.utf16)
        var j = 0
        func isLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func str(_ r: Range<Int>) -> String { String(utf16CodeUnits: Array(u[r]), count: r.count) }
        func readWord(_ k: inout Int) -> String {
            var w = ""
            while k < u.count, isLetter(u[k]) { w.append(Character(UnicodeScalar(u[k])!)); k += 1 }
            return w
        }
        func skipSpace(_ k: inout Int) { while k < u.count, u[k] == 0x20 || u[k] == 0x0A || u[k] == 0x09 { k += 1 } }
        func readBraces(_ k: inout Int) -> String? {
            skipSpace(&k)
            guard k < u.count, u[k] == 0x7B else { return nil }
            var depth = 1; var m = k + 1; let start = m
            while m < u.count, depth > 0 {
                if u[m] == 0x7B { depth += 1 } else if u[m] == 0x7D { depth -= 1; if depth == 0 { break } }
                m += 1
            }
            guard depth == 0 else { return nil }
            let s = str(start..<m)
            k = m + 1
            return s
        }
        func readBrackets(_ k: inout Int) -> String? {
            skipSpace(&k)
            guard k < u.count, u[k] == 0x5B else { return nil }
            var depth = 1; var m = k + 1; let start = m
            while m < u.count, depth > 0 {
                if u[m] == 0x5B { depth += 1 } else if u[m] == 0x5D { depth -= 1; if depth == 0 { break } }
                m += 1
            }
            guard depth == 0 else { return nil }
            let s = str(start..<m)
            k = m + 1
            return s
        }

        while j < u.count {
            guard u[j] == 0x5C else { j += 1; continue }
            var k = j + 1
            let name = readWord(&k)
            switch name {
            case "title": titleText = readBraces(&k)
            case "author": authorText = readBraces(&k)
            case "date": dateText = readBraces(&k)
            case "newcommand", "renewcommand", "providecommand":
                skipSpace(&k)
                if k < u.count, u[k] == 0x2A { k += 1 } // \newcommand*
                var cmdName: String?
                if k < u.count, u[k] == 0x7B {
                    k += 1
                    guard k < u.count, u[k] == 0x5C else { break }
                    k += 1
                    cmdName = readWord(&k)
                    skipSpace(&k)
                    if k < u.count, u[k] == 0x7D { k += 1 }
                } else {
                    skipSpace(&k)
                    if k < u.count, u[k] == 0x5C { k += 1; cmdName = readWord(&k) }
                }
                guard let cmdName, !cmdName.isEmpty else { break }
                var params = 0
                if let n = readBrackets(&k), let count = Int(n) { params = count }
                var defaultFirst: String?
                if params > 0 { defaultFirst = readBrackets(&k) }
                guard let body = readBraces(&k) else { break }
                macros[cmdName] = Macro(params: params, defaultFirst: defaultFirst, body: body)
            case "def":
                skipSpace(&k)
                guard k < u.count, u[k] == 0x5C else { break }
                k += 1
                let cmdName = readWord(&k)
                guard !cmdName.isEmpty else { break }
                var params = 0
                while k < u.count, u[k] == 0x23 /* # */ {
                    k += 1
                    if k < u.count, u[k] >= 0x31, u[k] <= 0x39 { k += 1; params += 1 }
                }
                guard let body = readBraces(&k) else { break }
                macros[cmdName] = Macro(params: params, defaultFirst: nil, body: body)
            case "DeclareMathOperator":
                skipSpace(&k)
                if k < u.count, u[k] == 0x2A { k += 1 }
                guard let nameArg = readBraces(&k), nameArg.hasPrefix("\\") else { break }
                guard let text = readBraces(&k) else { break }
                macros[String(nameArg.dropFirst())] = Macro(params: 0, defaultFirst: nil, body: "\\operatorname{\(text)}")
            case "newtheorem":
                skipSpace(&k)
                guard let envName = readBraces(&k) else { break }
                var sharedWith = readBrackets(&k)
                guard let displayName = readBraces(&k) else { break }
                _ = readBrackets(&k) // [withinCounter], unsupported nuance
                theorems[envName] = TheoremKind(displayName: displayName, counterKey: sharedWith ?? envName)
                sharedWith = nil
            default: break
            }
            j = k
        }
    }

    // MARK: Macro expansion

    /// Expands user macros across the whole body, tracking which output
    /// UTF-16 units map back to a real source offset (verbatim passthrough)
    /// versus synthesized macro output (offset -1, rendered with
    /// `.marginAnchor` rather than `.marginSource`).
    private func expand(_ source: String) -> (String, [Int]) {
        guard !macros.isEmpty else {
            let u = Array(source.utf16)
            return (source, Array(0..<u.count))
        }
        let src = Array(source.utf16)
        var outUnits: [unichar] = []
        var outOffsets: [Int] = []
        outUnits.reserveCapacity(src.count)
        outOffsets.reserveCapacity(src.count)
        var j = 0

        func isLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

        func readBraceGroup(_ k: inout Int) -> String? {
            guard k < src.count, src[k] == 0x7B else { return nil }
            var depth = 1; var m = k + 1; let start = m
            while m < src.count, depth > 0 {
                if src[m] == 0x7B { depth += 1 } else if src[m] == 0x7D { depth -= 1; if depth == 0 { break } }
                m += 1
            }
            guard depth == 0 else { return nil }
            let s = String(utf16CodeUnits: Array(src[start..<m]), count: m - start)
            k = m + 1
            return s
        }
        func readBracketGroup(_ k: inout Int) -> String? {
            guard k < src.count, src[k] == 0x5B else { return nil }
            var depth = 1; var m = k + 1; let start = m
            while m < src.count, depth > 0 {
                if src[m] == 0x5B { depth += 1 } else if src[m] == 0x5D { depth -= 1; if depth == 0 { break } }
                m += 1
            }
            guard depth == 0 else { return nil }
            let s = String(utf16CodeUnits: Array(src[start..<m]), count: m - start)
            k = m + 1
            return s
        }

        while j < src.count {
            if src[j] == 0x5C {
                var k = j + 1
                var name = ""
                while k < src.count, isLetter(src[k]) { name.append(Character(UnicodeScalar(src[k])!)); k += 1 }
                if !name.isEmpty, let macro = macros[name] {
                    var args: [String] = []
                    if macro.defaultFirst != nil, let opt = readBracketGroup(&k) {
                        args.append(opt)
                    }
                    var remaining = macro.params - args.count
                    while remaining > 0 {
                        while k < src.count, src[k] == 0x20 || src[k] == 0x0A { k += 1 }
                        if let g = readBraceGroup(&k) {
                            args.append(g)
                        } else if k < src.count {
                            args.append(String(utf16CodeUnits: [src[k]], count: 1)); k += 1
                        } else { break }
                        remaining -= 1
                    }
                    if args.count < macro.params, let d = macro.defaultFirst { args.insert(d, at: 0) }
                    let expansion = expandPlain(macro.body, args: args, depth: 0)
                    for u in expansion.utf16 { outUnits.append(u); outOffsets.append(-1) }
                    j = k
                    continue
                }
            }
            outUnits.append(src[j]); outOffsets.append(j)
            j += 1
        }
        return (String(utf16CodeUnits: outUnits, count: outUnits.count), outOffsets)
    }

    /// Plain (offset-unaware) recursive macro expansion, used for a macro's
    /// own body and for out-of-band text like the title page.
    private func expandPlain(_ text: String, args: [String] = [], depth: Int) -> String {
        guard depth < 8 else { return text }
        var body = text
        for (idx, arg) in args.enumerated() {
            body = body.replacingOccurrences(of: "#\(idx + 1)", with: arg)
        }
        guard !macros.isEmpty else { return body }
        let src = Array(body.utf16)
        var out = ""
        var j = 0
        func isLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func readBraceGroup(_ k: inout Int) -> String? {
            guard k < src.count, src[k] == 0x7B else { return nil }
            var depth2 = 1; var m = k + 1; let start = m
            while m < src.count, depth2 > 0 {
                if src[m] == 0x7B { depth2 += 1 } else if src[m] == 0x7D { depth2 -= 1; if depth2 == 0 { break } }
                m += 1
            }
            guard depth2 == 0 else { return nil }
            let s = String(utf16CodeUnits: Array(src[start..<m]), count: m - start)
            k = m + 1
            return s
        }
        while j < src.count {
            if src[j] == 0x5C {
                var k = j + 1
                var name = ""
                while k < src.count, isLetter(src[k]) { name.append(Character(UnicodeScalar(src[k])!)); k += 1 }
                if !name.isEmpty, let macro = macros[name], name != text {
                    var innerArgs: [String] = []
                    var remaining = macro.params
                    while remaining > 0 {
                        while k < src.count, src[k] == 0x20 { k += 1 }
                        if let g = readBraceGroup(&k) { innerArgs.append(g) }
                        else if k < src.count { innerArgs.append(String(utf16CodeUnits: [src[k]], count: 1)); k += 1 }
                        else { break }
                        remaining -= 1
                    }
                    out += expandPlain(macro.body, args: innerArgs, depth: depth + 1)
                    j = k
                    continue
                }
            }
            out.unicodeScalars.append(Unicode.Scalar(src[j]) ?? " ")
            j += 1
        }
        return out
    }

    // MARK: Paragraph flow

    private func flushParagraph() {
        guard paragraph.length > 0 else { return }
        let pstyle = NSMutableParagraphStyle()
        pstyle.lineSpacing = 4
        pstyle.paragraphSpacing = 10
        if !lastWasDisplay, paragraphIndented { pstyle.firstLineHeadIndent = 24 }
        paragraph.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: paragraph)
        output.append(paragraph)
        paragraph = NSMutableAttributedString()
        lastWasDisplay = false
        paragraphIndented = true
    }

    // MARK: Command dispatch

    private func handleCommand(target: NSMutableAttributedString) {
        let name = readControlWord()
        let topLevel = target === paragraph

        switch name {
        case "%", "$", "&", "#", "_": appendLiteral(name, target: target)
        case "{": appendLiteral("{", target: target)
        case "}": appendLiteral("}", target: target)
        case " ", "\n", ",", ";", "!": appendLiteral(" ", target: target)
        case "\\":
            _ = readBracketGroupRaw()
            if topLevel { flushParagraph() } else { target.append(NSAttributedString(string: "\n")) }
        case "textbackslash": appendLiteral("\\", target: target)
        case "textasciitilde": appendLiteral("~", target: target)
        case "textasciicircum": appendLiteral("^", target: target)
        case "ldots", "dots", "dotsc", "dotsb": appendLiteral("…", target: target)
        case "LaTeX": appendLiteral("LaTeX", target: target)
        case "TeX": appendLiteral("TeX", target: target)
        case "copyright": appendLiteral("©", target: target)
        case "dag": appendLiteral("†", target: target)

        case "(":
            let start = i
            let startOffset = currentOffset()
            while let c = currentUnit(), !(c == 0x5C && i + 1 < units.count && units[i + 1] == 0x29) { i += 1 }
            let raw = sliceRaw(start, i)
            if currentUnit() != nil { i += 2 }
            insertMath(raw, display: false, target: target, sourceOffset: startOffset)
        case "[":
            let start = i
            let startOffset = currentOffset()
            while let c = currentUnit(), !(c == 0x5C && i + 1 < units.count && units[i + 1] == 0x5D) { i += 1 }
            let raw = sliceRaw(start, i)
            if currentUnit() != nil { i += 2 }
            insertMath(raw, display: true, target: target, sourceOffset: startOffset)

        case "textbf": wrapStyle(target: target) { $0.bold = true }
        case "textit", "emph": wrapStyle(target: target) { $0.italic = true }
        case "texttt": wrapStyle(target: target) { $0.mono = true }
        case "textsc": wrapStyle(target: target) { $0.smallCaps = true }
        case "underline": wrapStyle(target: target) { $0.underline = true }
        case "textrm", "textnormal", "textsf", "mbox": wrapStyle(target: target) { _ in }

        case "bfseries": style.bold = true
        case "itshape": style.italic = true
        case "ttfamily": style.mono = true
        case "scshape": style.smallCaps = true
        case "normalfont", "mdseries", "upshape", "rmfamily", "sffamily":
            style.bold = false; style.italic = false; style.mono = false; style.smallCaps = false

        case "tiny": style.size = 9
        case "scriptsize": style.size = 10
        case "footnotesize": style.size = 11
        case "small": style.size = 13
        case "normalsize": style.size = 16
        case "large": style.size = 18
        case "Large": style.size = 20
        case "LARGE": style.size = 23
        case "huge": style.size = 26
        case "Huge": style.size = 30

        case "url":
            if let (raw, _) = readBraceGroupRaw() {
                var attrs: [NSAttributedString.Key: Any] = [.font: fontFor(style), .foregroundColor: NSColor.labelColor, .marginAnchor: currentOffset()]
                if let url = URL(string: raw) { attrs[.link] = url }
                target.append(NSAttributedString(string: raw, attributes: attrs))
            }
        case "href":
            if let (urlRaw, _) = readBraceGroupRaw() {
                let buf = captureInline()
                if let url = URL(string: urlRaw) { buf.addAttribute(.link, value: url, range: NSRange(location: 0, length: buf.length)) }
                target.append(buf)
            }

        case "'", "`", "^", "\"", "~", "=", ".", "u", "v", "H", "c", "k", "b", "d", "r":
            appendLiteral(String(readAccentedChar(command: name)), target: target)

        case "label":
            if let (n, _) = readBraceGroupRaw() { registerLabel(n) }
        case "ref": if let (n, _) = readBraceGroupRaw() { appendPendingRef(n, isEquation: false, target: target) }
        case "eqref": if let (n, _) = readBraceGroupRaw() { appendPendingRef(n, isEquation: true, target: target) }
        case "cite": if let (keys, _) = readBraceGroupRaw() { appendPendingCite(keys, target: target) }
        case "footnote": appendFootnoteMarker(target: target)

        case "section", "subsection", "subsubsection", "paragraph":
            if topLevel { emitHeading(level: name) } else { _ = readBraceGroupRaw() }
        case "begin":
            if topLevel, let (env, _) = readBraceGroupRaw() { emitEnvironment(env) }
            else if let (env, _) = readBraceGroupRaw() { _ = readRawUntilEnd(env) }
        case "maketitle": if topLevel { emitTitlePage() }
        case "appendix": appendixMode = true; sectionCounters = [0, 0, 0]
        case "noindent": paragraphIndented = false
        case "tableofcontents", "bibliographystyle", "bibliography", "includeonly", "input", "include":
            _ = readBraceGroupRaw()
        case "setlength", "setcounter", "addtolength":
            _ = readBraceGroupRaw(); _ = readBraceGroupRaw()
        case "vspace", "hspace":
            _ = readBraceGroupRaw()
        case "par", "newpage", "clearpage", "cleardoublepage", "bigskip", "medskip", "smallskip",
             "pagestyle", "thispagestyle", "hline", "centering", "raggedright", "raggedleft",
             "indent", "linebreak", "newline", "nopagebreak", "pagebreak", "protect", "relax":
            if name == "pagestyle" || name == "thispagestyle" { _ = readBraceGroupRaw() }

        default:
            // Unknown command: render the brace contents plainly (graceful degradation).
            let buf = captureInline()
            target.append(buf)
        }
    }

    // MARK: Environments

    private func emitEnvironment(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        switch name {
        case "itemize", "enumerate", "description": emitList(kind: name)
        case "quote", "quotation", "verse": emitQuote()
        case "center", "flushleft", "flushright": emitAligned(name)
        case "verbatim", "verbatim*", "lstlisting", "minted", "Verbatim": emitVerbatim(name)
        case "tabular", "tabular*", "array": emitTabularBlock()
        case "figure", "figure*", "table", "table*": emitFloat(kind: name)
        case "abstract": emitAbstract()
        case "thebibliography": emitBibliography()
        case "equation", "equation*", "align", "align*", "gather", "gather*",
             "multline", "multline*", "displaymath", "eqnarray", "eqnarray*":
            emitDisplayMathEnvironment(name)
        case "proof": emitProof()
        default:
            let stripped = name.hasSuffix("*") ? String(name.dropLast()) : name
            if let theorem = theorems[name] ?? theorems[stripped] {
                emitTheorem(envName: name, info: theorem)
            } else {
                _ = parseInline(into: paragraph, stopBefore: ["end"])
                consumeEnd(name)
            }
        }
    }

    private func emitHeading(level: String) {
        flushParagraph()
        let sizes: [String: CGFloat] = ["section": 22, "subsection": 18, "subsubsection": 16, "paragraph": 16]
        let size = sizes[level] ?? 16
        styleStack.append(style)
        style = Style(bold: true, size: size)
        let titleBuf = captureInline()
        style = styleStack.removeLast()

        var number = ""
        if level != "paragraph" {
            let idx = level == "section" ? 0 : (level == "subsection" ? 1 : 2)
            sectionCounters[idx] += 1
            for k in (idx + 1)..<sectionCounters.count { sectionCounters[k] = 0 }
            let parts = (0...idx).map { n -> String in
                (appendixMode && n == 0) ? alpha(sectionCounters[0]).uppercased() : "\(sectionCounters[n])"
            }
            number = parts.joined(separator: ".")
            lastNumberContext = number
        }

        let para = NSMutableAttributedString(string: number.isEmpty ? "" : number + "  ", attributes: [
            .font: MathFont.text(size, bold: true), .foregroundColor: NSColor.labelColor,
        ])
        para.append(titleBuf)
        let pstyle = NSMutableParagraphStyle()
        pstyle.paragraphSpacingBefore = size >= 20 ? 26 : 18
        pstyle.paragraphSpacing = 10
        para.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: para)
        output.append(para)
        lastWasDisplay = true
    }

    private func emitList(kind: String) {
        listDepth += 1
        while listCounters.count < listDepth { listCounters.append(0) }
        listCounters[listDepth - 1] = 0
        flushParagraph()
        while true {
            skipSpacesAndComments()
            guard let c = currentUnit() else { break }
            if c == 0x5C {
                if peekControlWord() == "end" { break }
                if peekControlWord() == "item" {
                    _ = readControlWord()
                    var term: NSAttributedString?
                    if kind == "description" {
                        skipSpacesAndComments()
                        if currentUnit() == 0x5B, let raw = readBracketGroupRaw() {
                            term = renderFragment(raw, bold: true)
                        }
                    }
                    var marker = ""
                    switch kind {
                    case "itemize":
                        marker = ["•", "◦", "▪"][min(listDepth - 1, 2)]
                    case "enumerate":
                        listCounters[listDepth - 1] += 1
                        let n = listCounters[listDepth - 1]
                        switch (listDepth - 1) % 3 {
                        case 0: marker = "\(n)."
                        case 1: marker = "\(alpha(n))."
                        default: marker = "\(roman(n))."
                        }
                    default: break
                    }
                    let itemBuf = NSMutableAttributedString()
                    _ = parseInline(into: itemBuf, stopBefore: ["end", "item"])
                    emitListItem(marker: marker, term: term, body: itemBuf)
                    continue
                }
            }
            i += 1
        }
        consumeEnd(kind)
        listDepth -= 1
        lastWasDisplay = true
    }

    private func emitListItem(marker: String, term: NSAttributedString?, body: NSMutableAttributedString) {
        let indent: CGFloat = 26
        let head = indent * CGFloat(listDepth)
        let pstyle = NSMutableParagraphStyle()
        pstyle.headIndent = head
        pstyle.firstLineHeadIndent = head - indent + 6
        pstyle.tabStops = [NSTextTab(textAlignment: .left, location: head)]
        pstyle.paragraphSpacing = 5
        pstyle.lineSpacing = 4

        let line = NSMutableAttributedString()
        if let term {
            line.append(NSAttributedString(string: "\t"))
            line.append(term)
            line.append(NSAttributedString(string: " "))
        } else {
            line.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: fontFor(style), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        line.append(body)
        line.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: line)
        output.append(line)
    }

    private func emitQuote() {
        flushParagraph()
        let buf = NSMutableAttributedString()
        _ = parseInline(into: buf, stopBefore: ["end"])
        consumeEnd("quote")
        let block = QuoteBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(16, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        let pstyle = NSMutableParagraphStyle()
        pstyle.textBlocks = [block]
        pstyle.lineSpacing = 4
        pstyle.paragraphSpacing = 12
        if buf.length > 0 {
            buf.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: buf.length))
        }
        buf.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: buf)
        output.append(buf)
        lastWasDisplay = true
    }

    private func emitAligned(_ kind: String) {
        flushParagraph()
        let buf = NSMutableAttributedString()
        _ = parseInline(into: buf, stopBefore: ["end"])
        consumeEnd(kind)
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = kind == "center" ? .center : (kind == "flushright" ? .right : .left)
        pstyle.paragraphSpacing = 10
        buf.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: buf)
        output.append(buf)
        lastWasDisplay = true
    }

    private func emitVerbatim(_ kind: String) {
        flushParagraph()
        if kind == "minted" { _ = readBraceGroupRaw() }
        let offset = currentOffset()
        var raw = readRawUntilEnd(kind)
        if raw.hasPrefix("\n") { raw.removeFirst() }
        while raw.hasSuffix("\n") { raw.removeLast() }
        let block = CodeBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(14, type: .absoluteValueType, for: .padding)
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
        let pstyle = NSMutableParagraphStyle()
        pstyle.textBlocks = [block]
        pstyle.lineSpacing = 3
        let text = NSMutableAttributedString(string: raw, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor,
            .marginAnchor: offset,
        ])
        text.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: text)
        output.append(text)
        lastWasDisplay = true
    }

    // MARK: Tables

    private enum TableStop { case amp, row, end }

    private func readTableCellRaw() -> (text: String, stop: TableStop) {
        var depth = 0
        let start = i
        while let c = currentUnit() {
            if c == 0x7B { depth += 1; i += 1; continue }
            if c == 0x7D { depth -= 1; i += 1; continue }
            if depth == 0, c == 0x26 {
                let text = sliceRaw(start, i); i += 1; return (text, .amp)
            }
            if depth == 0, c == 0x5C {
                if i + 1 < units.count, units[i + 1] == 0x5C {
                    let text = sliceRaw(start, i); i += 2
                    skipSpacesAndComments()
                    if currentUnit() == 0x5B { _ = readBracketGroupRaw() }
                    return (text, .row)
                }
                if peekControlWord() == "end" { return (sliceRaw(start, i), .end) }
            }
            i += 1
        }
        return (sliceRaw(start, i), .end)
    }

    private func emitTabularBlock() {
        skipSpacesAndComments()
        var colSpec = ""
        if currentUnit() == 0x7B, let (spec, _) = readBraceGroupRaw() { colSpec = spec }
        let aligns: [NSTextAlignment] = colSpec.compactMap { ch in
            switch ch { case "l": return .left; case "c": return .center; case "r": return .right; default: return nil }
        }
        let columnCount = max(aligns.count, 1)
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        var row = 0
        var boldNextFlush = false
        var pendingBold = false

        rows: while true {
            skipSpacesAndComments()
            guard currentUnit() != nil else { break }
            if currentUnit() == 0x5C, peekControlWord() == "end" { break }
            if currentUnit() == 0x5C, let word = peekControlWord(),
               ["hline", "toprule", "midrule", "bottomrule", "cline"].contains(word) {
                _ = readControlWord()
                if word == "cline" { _ = readBraceGroupRaw() }
                if row == 1 { boldNextFlush = true }
                continue
            }

            var column = 0
            var cells: [(NSMutableAttributedString, Int)] = []
            cellLoop: while true {
                skipSpacesAndComments()
                if currentUnit() == 0x5C, peekControlWord() == "multicolumn" {
                    _ = readControlWord()
                    let span = Int(readBraceGroupRaw()?.text ?? "1") ?? 1
                    _ = readBraceGroupRaw()
                    let buf = NSMutableAttributedString()
                    skipSpacesAndComments()
                    if currentUnit() == 0x7B {
                        i += 1
                        let reason = parseInline(into: buf, stopBrace: true, stopRow: true, stopBefore: ["end"])
                        if currentUnit() == 0x7D { i += 1 }
                        cells.append((buf, span))
                        column += span
                        if case .rowBreak = reason { break cellLoop }
                        if case .command = reason { break rows }
                        skipSpacesAndComments()
                        if currentUnit() == 0x26 { i += 1; continue cellLoop }
                        if currentUnit() == 0x5C, i + 1 < units.count, units[i + 1] == 0x5C { i += 2; break cellLoop }
                        break cellLoop
                    }
                } else {
                    let (raw, stop) = readTableCellRaw()
                    let buf = renderFragment(raw)
                    cells.append((NSMutableAttributedString(attributedString: buf), 1))
                    column += 1
                    switch stop {
                    case .amp: continue cellLoop
                    case .row: break cellLoop
                    case .end: break cellLoop
                    }
                }
            }
            row += 1
            pendingBold = boldNextFlush
            boldNextFlush = false
            var col = 0
            for (buf, span) in cells {
                let cellBlock = NSTextTableBlock(table: table, startingRow: row - 1, rowSpan: 1, startingColumn: col, columnSpan: span)
                cellBlock.setBorderColor(Theme.hairline)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                cellBlock.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cellBlock.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                if pendingBold { cellBlock.backgroundColor = Theme.codeBackground }
                let pstyle = NSMutableParagraphStyle()
                pstyle.alignment = col < aligns.count ? aligns[col] : .left
                pstyle.textBlocks = [cellBlock]
                if pendingBold, buf.length > 0 {
                    buf.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .semibold), range: NSRange(location: 0, length: buf.length))
                }
                buf.append(NSAttributedString(string: "\n"))
                applyDefaultParagraphStyle(pstyle, to: buf)
                output.append(buf)
                col += span
            }
        }
        consumeEnd("tabular")
        lastWasDisplay = true
    }

    // MARK: Figures / tables (floats)

    private func makeImageAttachment(_ path: String) -> NSTextAttachment? {
        var url: URL?
        if let u = URL(string: path), u.scheme != nil {
            url = u
        } else if let baseURL {
            url = URL(fileURLWithPath: path, relativeTo: baseURL).absoluteURL
        }
        guard let url, let image = ImageStore.shared.image(for: url) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let scale = min(1, 480 / max(image.size.width, 1))
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return attachment
    }

    private func emitFloat(kind: String) {
        let isTable = kind.hasPrefix("table")
        var imageAttachment: NSTextAttachment?
        var captionBuf: NSMutableAttributedString?
        var labelName: String?

        while true {
            skipSpacesAndComments()
            guard let c = currentUnit() else { break }
            if c == 0x5C {
                if peekControlWord() == "end" { break }
                let word = readControlWord()
                switch word {
                case "includegraphics":
                    _ = readBracketGroupRaw()
                    if let (path, _) = readBraceGroupRaw() { imageAttachment = makeImageAttachment(path) }
                case "caption":
                    styleStack.append(style); style = Style(size: 14)
                    captionBuf = captureInline()
                    style = styleStack.removeLast()
                case "label":
                    if let (n, _) = readBraceGroupRaw() { labelName = n }
                case "begin":
                    if let (env, _) = readBraceGroupRaw() {
                        if env.hasPrefix("tabular") { emitTabularBlock() } else { _ = readRawUntilEnd(env) }
                    }
                case "centering", "small", "footnotesize", "scriptsize", "hline": break
                default: _ = readBraceGroupRaw()
                }
            } else {
                i += 1
            }
        }
        consumeEnd(kind)
        flushParagraph()

        if let imageAttachment {
            let p = NSMutableAttributedString(attributedString: NSAttributedString(attachment: imageAttachment))
            let pstyle = NSMutableParagraphStyle(); pstyle.alignment = .center; pstyle.paragraphSpacing = 6
            p.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: p)
            output.append(p)
        }
        if let captionBuf {
            if isTable { tableCounter += 1 } else { figureCounter += 1 }
            let n = isTable ? tableCounter : figureCounter
            let prefix = isTable ? "Table \(n): " : "Figure \(n): "
            lastNumberContext = "\(n)"
            if let labelName { labels[labelName] = "\(n)" }
            let line = NSMutableAttributedString(string: prefix, attributes: [
                .font: MathFont.text(13, bold: true), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            line.append(captionBuf)
            let pstyle = NSMutableParagraphStyle(); pstyle.alignment = .center; pstyle.paragraphSpacing = 16
            line.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: line)
            output.append(line)
        }
        lastWasDisplay = true
    }

    // MARK: Abstract / bibliography / proof / theorems

    private func emitAbstract() {
        flushParagraph()
        styleStack.append(style); style = Style(italic: true, size: 14)
        let buf = NSMutableAttributedString()
        _ = parseInline(into: buf, stopBefore: ["end"])
        style = styleStack.removeLast()
        consumeEnd("abstract")

        let header = NSMutableAttributedString(string: "Abstract\n", attributes: [
            .font: MathFont.text(14, bold: true), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let hstyle = NSMutableParagraphStyle(); hstyle.paragraphSpacingBefore = 16; hstyle.paragraphSpacing = 4
        applyDefaultParagraphStyle(hstyle, to: header)
        output.append(header)

        let pstyle = NSMutableParagraphStyle(); pstyle.firstLineHeadIndent = 24; pstyle.paragraphSpacing = 14; pstyle.lineSpacing = 4
        buf.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: buf)
        output.append(buf)
        lastWasDisplay = true
    }

    private func emitBibliography() {
        flushParagraph()
        _ = readBraceGroupRaw()
        var items: [(number: Int, text: NSAttributedString)] = []
        while true {
            skipSpacesAndComments()
            guard let c = currentUnit() else { break }
            if c == 0x5C {
                if peekControlWord() == "end" { break }
                if peekControlWord() == "bibitem" {
                    _ = readControlWord()
                    _ = readBracketGroupRaw()
                    guard let (key, _) = readBraceGroupRaw() else { continue }
                    bibCount += 1
                    bibIndex[key] = bibCount
                    let buf = NSMutableAttributedString()
                    _ = parseInline(into: buf, stopBefore: ["end", "bibitem"])
                    items.append((bibCount, buf))
                    continue
                }
            }
            i += 1
        }
        consumeEnd("thebibliography")
        bibliographyRendered = true

        let header = NSMutableAttributedString(string: "References\n", attributes: [
            .font: MathFont.text(18, bold: true), .foregroundColor: NSColor.labelColor,
        ])
        let hstyle = NSMutableParagraphStyle(); hstyle.paragraphSpacingBefore = 24; hstyle.paragraphSpacing = 10
        applyDefaultParagraphStyle(hstyle, to: header)
        output.append(header)
        for item in items {
            let line = NSMutableAttributedString(string: "[\(item.number)] ", attributes: [
                .font: MathFont.text(13), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            line.append(item.text)
            let pstyle = NSMutableParagraphStyle(); pstyle.paragraphSpacing = 8; pstyle.lineSpacing = 3; pstyle.headIndent = 20
            line.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: line)
            output.append(line)
        }
        lastWasDisplay = true
    }

    private func emitProof() {
        flushParagraph()
        var heading = "Proof"
        skipSpacesAndComments()
        if currentUnit() == 0x5B, let opt = readBracketGroupRaw() { heading = opt }
        let buf = NSMutableAttributedString(string: "\(heading). ", attributes: [
            .font: MathFont.text(15, italic: true), .foregroundColor: NSColor.labelColor,
        ])
        let body = NSMutableAttributedString()
        _ = parseInline(into: body, stopBefore: ["end"])
        consumeEnd("proof")
        trimTrailingWhitespace(body)
        buf.append(body)
        buf.append(NSAttributedString(string: " \u{25A0}", attributes: [.font: MathFont.text(15)]))
        let pstyle = NSMutableParagraphStyle(); pstyle.paragraphSpacing = 12; pstyle.lineSpacing = 4
        buf.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: buf)
        output.append(buf)
        lastWasDisplay = true
    }

    private func emitTheorem(envName: String, info: TheoremKind) {
        flushParagraph()
        let starred = envName.hasSuffix("*")
        var heading = info.displayName
        if !starred {
            theoremCounters[info.counterKey, default: 0] += 1
            heading += " \(theoremCounters[info.counterKey]!)"
            lastNumberContext = "\(theoremCounters[info.counterKey]!)"
        }
        skipSpacesAndComments()
        if currentUnit() == 0x5B, let note = readBracketGroupRaw() { heading += " (\(note))" }

        let header = NSMutableAttributedString(string: "\(heading). ", attributes: [
            .font: MathFont.text(15, bold: true), .foregroundColor: NSColor.labelColor,
        ])
        styleStack.append(style); style = Style(italic: true, size: 15)
        let body = NSMutableAttributedString()
        _ = parseInline(into: body, stopBefore: ["end"])
        style = styleStack.removeLast()
        consumeEnd(envName)
        header.append(body)
        let pstyle = NSMutableParagraphStyle(); pstyle.paragraphSpacing = 12; pstyle.lineSpacing = 4; pstyle.paragraphSpacingBefore = 10
        header.append(NSAttributedString(string: "\n"))
        applyDefaultParagraphStyle(pstyle, to: header)
        output.append(header)
        lastWasDisplay = true
    }

    // MARK: Title page

    private func emitTitlePage() {
        flushParagraph()
        if let titleText {
            let buf = NSMutableAttributedString(attributedString: renderFragment(titleText))
            buf.addAttribute(.font, value: MathFont.text(26, bold: true), range: NSRange(location: 0, length: buf.length))
            let pstyle = NSMutableParagraphStyle(); pstyle.alignment = .center; pstyle.paragraphSpacing = 10; pstyle.paragraphSpacingBefore = 6
            buf.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: buf)
            output.append(buf)
        }
        if let authorText {
            let buf = NSMutableAttributedString(attributedString: renderFragment(authorText))
            buf.addAttribute(.font, value: MathFont.text(16), range: NSRange(location: 0, length: buf.length))
            buf.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: buf.length))
            let pstyle = NSMutableParagraphStyle(); pstyle.alignment = .center; pstyle.paragraphSpacing = 6
            buf.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: buf)
            output.append(buf)
        }
        if let dateText {
            let text = dateText == "\\today" ? DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none) : dateText
            let buf = NSMutableAttributedString(attributedString: renderFragment(text))
            buf.addAttribute(.font, value: MathFont.text(14), range: NSRange(location: 0, length: buf.length))
            buf.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: buf.length))
            let pstyle = NSMutableParagraphStyle(); pstyle.alignment = .center; pstyle.paragraphSpacing = 22
            buf.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: buf)
            output.append(buf)
        }
        lastWasDisplay = true
    }

    // MARK: Labels, references, citations, footnotes

    private func registerLabel(_ name: String) {
        labels[name] = lastNumberContext ?? "?"
    }

    private func appendPendingRef(_ name: String, isEquation: Bool, target: NSMutableAttributedString) {
        target.append(NSAttributedString(string: "\u{FFFC}", attributes: [
            .font: fontFor(style), .foregroundColor: NSColor.controlAccentColor,
            Self.pendingRefKey: name, Self.pendingRefKindKey: isEquation,
        ]))
    }

    private func appendPendingCite(_ keys: String, target: NSMutableAttributedString) {
        target.append(NSAttributedString(string: "\u{FFFC}", attributes: [
            .font: fontFor(style), .foregroundColor: NSColor.controlAccentColor, Self.pendingCiteKey: keys,
        ]))
    }

    private func appendFootnoteMarker(target: NSMutableAttributedString) {
        guard let (text, _) = readBraceGroupRaw() else { return }
        let number = footnotes.count + 1
        target.append(NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: style.size * 0.7), .foregroundColor: NSColor.controlAccentColor,
            .baselineOffset: style.size * 0.35, .marginAnchor: currentOffset(),
        ]))
        footnotes.append(renderFragment(text))
    }

    private func appendFootnotesSection() {
        let header = NSMutableAttributedString(string: "Notes\n", attributes: [
            .font: MathFont.text(13, bold: true), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let hstyle = NSMutableParagraphStyle(); hstyle.paragraphSpacingBefore = 20; hstyle.paragraphSpacing = 6
        applyDefaultParagraphStyle(hstyle, to: header)
        output.append(header)
        for (idx, text) in footnotes.enumerated() {
            let line = NSMutableAttributedString(string: "\(idx + 1). ", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            line.append(text)
            let pstyle = NSMutableParagraphStyle(); pstyle.paragraphSpacing = 4; pstyle.lineSpacing = 2
            line.append(NSAttributedString(string: "\n"))
            applyDefaultParagraphStyle(pstyle, to: line)
            output.append(line)
        }
    }

    private static let pendingRefKey = NSAttributedString.Key("LaTeXPendingRef")
    private static let pendingRefKindKey = NSAttributedString.Key("LaTeXPendingRefIsEquation")
    private static let pendingCiteKey = NSAttributedString.Key("LaTeXPendingCite")

    private func resolvePendingRuns() {
        var replacements: [(NSRange, String)] = []
        output.enumerateAttribute(Self.pendingRefKey, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard let name = value as? String else { return }
            let isEquation = (output.attribute(Self.pendingRefKindKey, at: range.location, effectiveRange: nil) as? Bool) ?? false
            var text = labels[name] ?? "??"
            if !isEquation, text.hasPrefix("("), text.hasSuffix(")") {
                text = String(text.dropFirst().dropLast())
            }
            replacements.append((range, text))
        }
        output.enumerateAttribute(Self.pendingCiteKey, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard let keys = value as? String else { return }
            let parts = keys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers = parts.map { key -> String in bibIndex[key].map { "\($0)" } ?? key }
            replacements.append((range, "[" + numbers.joined(separator: ",") + "]"))
        }
        for (range, text) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            output.replaceCharacters(in: range, with: text)
        }
    }
}
