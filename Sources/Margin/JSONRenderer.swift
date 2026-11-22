import AppKit

// MARK: - Parsing

/// A parsed JSON value that remembers where each piece sits in the source,
/// so the preview can point back at it (for editing and locked scrolling).
indirect enum JSONNode {
    case object([(key: JSONString, value: JSONNode)])
    case array([JSONNode])
    case string(JSONString)
    case literal(String, NSRange)   // numbers, true, false, null, exactly as written

    var count: Int {
        switch self {
        case .object(let members): members.count
        case .array(let items): items.count
        default: 0
        }
    }
}

struct JSONString {
    /// Decoded value.
    var value: String
    /// The characters between the quotes.
    var inner: NSRange
    /// True when the source has no escapes, so `value` is the source text itself.
    var verbatim: Bool
}

struct JSONError: Error {
    var offset: Int
    var message: String
}

/// A strict JSON parser over UTF-16, tolerant only of // and /* */ comments.
struct JSONParser {
    private let chars: [unichar]
    private var i = 0

    init(_ text: String) {
        chars = Array(text.utf16)
    }

    static func parse(_ text: String) -> Result<JSONNode, JSONError> {
        var parser = JSONParser(text)
        do {
            parser.skip()
            let node = try parser.value(depth: 0)
            parser.skip()
            if parser.i < parser.chars.count {
                throw JSONError(offset: parser.i, message: "Unexpected text after the end of the JSON value")
            }
            return .success(node)
        } catch let error as JSONError {
            return .failure(error)
        } catch {
            return .failure(JSONError(offset: 0, message: "Could not read this JSON"))
        }
    }

    private var current: unichar? { i < chars.count ? chars[i] : nil }

    private mutating func skip() {
        while i < chars.count {
            let c = chars[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                i += 1
            } else if c == 0x2F, i + 1 < chars.count, chars[i + 1] == 0x2F {
                while i < chars.count, chars[i] != 0x0A { i += 1 }
            } else if c == 0x2F, i + 1 < chars.count, chars[i + 1] == 0x2A {
                i += 2
                while i + 1 < chars.count, !(chars[i] == 0x2A && chars[i + 1] == 0x2F) { i += 1 }
                i = min(chars.count, i + 2)
            } else {
                return
            }
        }
    }

    private mutating func value(depth: Int) throws -> JSONNode {
        guard depth < 512 else { throw JSONError(offset: i, message: "Nested too deeply") }
        guard let c = current else { throw JSONError(offset: i, message: "Expected a value") }
        switch c {
        case 0x7B: return try object(depth: depth)
        case 0x5B: return try array(depth: depth)
        case 0x22: return .string(try string())
        case 0x74: return try word("true")
        case 0x66: return try word("false")
        case 0x6E: return try word("null")
        case 0x2D, 0x30...0x39: return try number()
        default:
            throw JSONError(offset: i, message: "Expected a value, found “\(Character(UnicodeScalar(c) ?? "?"))”")
        }
    }

    private mutating func object(depth: Int) throws -> JSONNode {
        i += 1
        var members: [(key: JSONString, value: JSONNode)] = []
        skip()
        if current == 0x7D { i += 1; return .object(members) }
        while true {
            skip()
            guard current == 0x22 else {
                throw JSONError(offset: i, message: members.isEmpty ? "Expected a key in quotes or “}”" : "Expected a key in quotes")
            }
            let key = try string()
            skip()
            guard current == 0x3A else { throw JSONError(offset: i, message: "Expected “:” after the key") }
            i += 1
            skip()
            members.append((key, try value(depth: depth + 1)))
            skip()
            if current == 0x2C { i += 1; continue }
            if current == 0x7D { i += 1; return .object(members) }
            throw JSONError(offset: i, message: "Expected “,” or “}”")
        }
    }

    private mutating func array(depth: Int) throws -> JSONNode {
        i += 1
        var items: [JSONNode] = []
        skip()
        if current == 0x5D { i += 1; return .array(items) }
        while true {
            skip()
            items.append(try value(depth: depth + 1))
            skip()
            if current == 0x2C { i += 1; continue }
            if current == 0x5D { i += 1; return .array(items) }
            throw JSONError(offset: i, message: "Expected “,” or “]”")
        }
    }

    private mutating func string() throws -> JSONString {
        let open = i
        i += 1
        var units: [unichar] = []
        var verbatim = true
        while true {
            guard let c = current else { throw JSONError(offset: open, message: "This string is never closed") }
            if c == 0x22 { break }
            if c == 0x0A { throw JSONError(offset: i, message: "Line break inside a string") }
            if c == 0x5C {
                verbatim = false
                i += 1
                guard let e = current else { throw JSONError(offset: i, message: "Unfinished escape") }
                switch e {
                case 0x22, 0x5C, 0x2F: units.append(e)
                case 0x62: units.append(0x08)
                case 0x66: units.append(0x0C)
                case 0x6E: units.append(0x0A)
                case 0x72: units.append(0x0D)
                case 0x74: units.append(0x09)
                case 0x75:
                    guard i + 4 < chars.count,
                          let code = UInt16(String(utf16CodeUnits: Array(chars[(i + 1)...(i + 4)]), count: 4), radix: 16) else {
                        throw JSONError(offset: i, message: "Bad \\u escape")
                    }
                    units.append(code)
                    i += 4
                default:
                    throw JSONError(offset: i - 1, message: "Unknown escape “\\\(Character(UnicodeScalar(e) ?? "?"))”")
                }
                i += 1
                continue
            }
            units.append(c)
            i += 1
        }
        let inner = NSRange(location: open + 1, length: i - open - 1)
        i += 1
        return JSONString(value: String(utf16CodeUnits: units, count: units.count), inner: inner, verbatim: verbatim)
    }

    private mutating func word(_ word: String) throws -> JSONNode {
        let start = i
        for unit in word.utf16 {
            guard current == unit else { throw JSONError(offset: start, message: "Expected a value") }
            i += 1
        }
        return .literal(word, NSRange(location: start, length: i - start))
    }

    private mutating func number() throws -> JSONNode {
        let start = i
        if current == 0x2D { i += 1 }
        guard let first = current, (0x30...0x39).contains(first) else {
            throw JSONError(offset: i, message: "Expected a digit")
        }
        while let c = current, (0x30...0x39).contains(c) { i += 1 }
        if current == 0x2E {
            i += 1
            guard let c = current, (0x30...0x39).contains(c) else { throw JSONError(offset: i, message: "Expected a digit after “.”") }
            while let c = current, (0x30...0x39).contains(c) { i += 1 }
        }
        if current == 0x65 || current == 0x45 {
            i += 1
            if current == 0x2B || current == 0x2D { i += 1 }
            guard let c = current, (0x30...0x39).contains(c) else { throw JSONError(offset: i, message: "Expected a digit in the exponent") }
            while let c = current, (0x30...0x39).contains(c) { i += 1 }
        }
        let range = NSRange(location: start, length: i - start)
        return .literal(String(utf16CodeUnits: Array(chars[start..<i]), count: i - start), range)
    }
}

// MARK: - Preview

enum JSONRenderer {
    private static let size: CGFloat = 14
    private static let keyFont = NSFont.systemFont(ofSize: size, weight: .medium)
    private static let valueFont = NSFont.systemFont(ofSize: size)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    private static let noteFont = NSFont.systemFont(ofSize: 12)
    private static let indent: CGFloat = 22

    static func render(_ text: String) -> NSAttributedString {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSAttributedString(string: "Empty JSON document\n", attributes: [
                .font: valueFont, .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
        switch JSONParser.parse(text) {
        case .success(let root):
            let output = NSMutableAttributedString()
            switch root {
            case .object, .array:
                children(of: root, depth: 0, into: output)
            default:
                line(key: nil, value: root, depth: 0, into: output)
            }
            return output
        case .failure(let error):
            return invalid(text, error: error)
        }
    }

    // MARK: Valid documents

    private static func children(of node: JSONNode, depth: Int, into output: NSMutableAttributedString) {
        switch node {
        case .object(let members):
            if members.isEmpty { empty("No fields", depth: depth, into: output) }
            let column = keyColumn(members.map(\.key.value))
            for member in members {
                line(key: .named(member.key), value: member.value, depth: depth, column: column, into: output)
            }
        case .array(let items):
            if items.isEmpty { empty("No items", depth: depth, into: output) }
            let column = keyColumn(["\(max(items.count - 1, 0))"])
            for (index, item) in items.enumerated() {
                line(key: .index(index), value: item, depth: depth, column: column, into: output)
            }
        default:
            break
        }
    }

    private enum Key {
        case named(JSONString)
        case index(Int)
    }

    /// Where values start: just past the widest key, within reason.
    private static func keyColumn(_ keys: [String]) -> CGFloat {
        let widest = keys.prefix(400).map { ($0 as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0
        return min(max(widest, 24), 220) + 18
    }

    private static func line(key: Key?, value: JSONNode, depth: Int, column: CGFloat = 0, into output: NSMutableAttributedString) {
        let head = indent * CGFloat(depth)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = head
        style.headIndent = head + column
        style.tabStops = [NSTextTab(textAlignment: .left, location: head + column)]
        style.lineSpacing = 3
        style.paragraphSpacing = 5
        if depth == 0, output.length > 0, value.count > 0 { style.paragraphSpacingBefore = 8 }

        let text = NSMutableAttributedString()
        switch key {
        case .named(let name):
            var attributes: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor]
            if name.verbatim, name.inner.length > 0 { attributes[.marginSource] = name.inner.location }
            else { attributes[.marginAnchor] = name.inner.location }
            text.append(NSAttributedString(string: name.value.isEmpty ? "\u{201C}\u{201D}" : name.value, attributes: attributes))
            text.append(NSAttributedString(string: "\t", attributes: [.font: keyFont]))
        case .index(let index):
            text.append(NSAttributedString(string: "\(index)\t", attributes: [
                .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        case nil:
            break
        }

        switch value {
        case .object(let members):
            text.append(summary(members.count == 1 ? "1 field" : "\(members.count) fields", symbol: "{ }"))
        case .array(let items):
            text.append(summary(items.count == 1 ? "1 item" : "\(items.count) items", symbol: "[ ]"))
        case .string(let string):
            if string.value.isEmpty {
                text.append(NSAttributedString(string: "empty", attributes: [
                    .font: noteFont, .foregroundColor: NSColor.tertiaryLabelColor, .marginAnchor: string.inner.location,
                ]))
            } else {
                var attributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.labelColor]
                if string.verbatim { attributes[.marginSource] = string.inner.location }
                else { attributes[.marginAnchor] = string.inner.location }
                if let url = URL(string: string.value), url.scheme == "https" || url.scheme == "http" {
                    attributes[.link] = url
                }
                // Keep multi-line strings inside this entry.
                let shown = string.verbatim ? string.value : string.value.replacingOccurrences(of: "\n", with: "\u{2028}")
                text.append(NSAttributedString(string: shown, attributes: attributes))
            }
        case .literal(let raw, let range):
            let isNull = raw == "null"
            text.append(NSAttributedString(string: raw, attributes: [
                .font: isNull ? NSFont.systemFont(ofSize: size).italic : numberFont,
                .foregroundColor: isNull ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor,
                .marginSource: range.location,
            ]))
        }

        text.append(NSAttributedString(string: "\n", attributes: [.font: valueFont]))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        output.append(text)

        if value.count > 0 {
            children(of: value, depth: depth + 1, into: output)
        }
    }

    private static func summary(_ text: String, symbol: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: symbol + "  ", attributes: [
            .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        result.append(NSAttributedString(string: text, attributes: [
            .font: noteFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        return result
    }

    private static func empty(_ text: String, depth: Int, into output: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent * CGFloat(depth)
        style.paragraphSpacing = 5
        output.append(NSAttributedString(string: text + "\n", attributes: [
            .font: noteFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
        ]))
    }

    // MARK: Invalid documents

    /// Shows what is wrong and where, above the source with that line marked.
    private static func invalid(_ text: String, error: JSONError) -> NSAttributedString {
        let source = text as NSString
        let offset = min(max(error.offset, 0), source.length)
        var line = 1
        var lineStart = 0
        var index = 0
        while index < offset {
            if source.character(at: index) == 0x0A { line += 1; lineStart = index + 1 }
            index += 1
        }
        let column = offset - lineStart + 1

        let output = NSMutableAttributedString()

        let banner = BannerBlock()
        banner.setContentWidth(100, type: .percentageValueType)
        banner.setWidth(12, type: .absoluteValueType, for: .padding)
        banner.setWidth(16, type: .absoluteValueType, for: .margin, edge: .maxY)
        let bannerStyle = NSMutableParagraphStyle()
        bannerStyle.textBlocks = [banner]
        bannerStyle.lineSpacing = 3
        let message = NSMutableAttributedString(string: "This JSON has a problem\u{2028}", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        message.append(NSAttributedString(string: "Line \(line), column \(column): \(error.message)", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        message.append(NSAttributedString(string: "\n"))
        message.addAttribute(.paragraphStyle, value: bannerStyle, range: NSRange(location: 0, length: message.length))
        output.append(message)

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: codeStyle,
            .marginSource: 0,
        ])
        let bad = source.lineRange(for: NSRange(location: min(offset, max(source.length - 1, 0)), length: 0))
        if bad.length > 0 {
            body.addAttributes([.foregroundColor: NSColor.labelColor, .backgroundColor: BannerBlock.tint], range: bad)
        }
        output.append(body)
        if !text.hasSuffix("\n") { output.append(NSAttributedString(string: "\n")) }
        return output
    }

    // MARK: Formatting

    /// Re-indents valid JSON with two spaces, keeping key order and the exact
    /// spelling of every string and number. Nil when the text isn't valid.
    static func format(_ text: String) -> String? {
        guard case .success(let root) = JSONParser.parse(text) else { return nil }
        let source = text as NSString
        var out = ""
        func raw(_ string: JSONString) -> String {
            "\"" + source.substring(with: string.inner) + "\""
        }
        func write(_ node: JSONNode, _ level: Int) {
            let pad = String(repeating: "  ", count: level + 1)
            let close = String(repeating: "  ", count: level)
            switch node {
            case .object(let members):
                if members.isEmpty { out += "{}"; return }
                out += "{\n"
                for (index, member) in members.enumerated() {
                    out += pad + raw(member.key) + ": "
                    write(member.value, level + 1)
                    out += index < members.count - 1 ? ",\n" : "\n"
                }
                out += close + "}"
            case .array(let items):
                if items.isEmpty { out += "[]"; return }
                out += "[\n"
                for (index, item) in items.enumerated() {
                    out += pad
                    write(item, level + 1)
                    out += index < items.count - 1 ? ",\n" : "\n"
                }
                out += close + "]"
            case .string(let string):
                out += raw(string)
            case .literal(let raw, _):
                out += raw
            }
        }
        write(root, 0)
        return out + "\n"
    }
}

/// A softly tinted rounded panel, used for the "this JSON has a problem" note.
final class BannerBlock: NSTextBlock {
    static let tint = Theme.dynamic(
        light: NSColor.systemRed.withAlphaComponent(0.09),
        dark: NSColor.systemRed.withAlphaComponent(0.16)
    )

    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        Self.tint.setFill()
        NSBezierPath(roundedRect: inner(frame), xRadius: 8, yRadius: 8).fill()
    }
}

extension NSFont {
    var italic: NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(.italic), size: pointSize) ?? self
    }
}
