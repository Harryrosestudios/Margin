import AppKit

// MARK: - Theme

enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static let codeBackground = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.075))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.17))
    static let quoteBar = dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.22))

    static let lineHighlight = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))

    static let bodySize: CGFloat = 15
    static let headingSizes: [CGFloat] = [30, 23, 19, 16, 15, 14]

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, mono: Bool = false) -> NSFont {
        let font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
    }
}

// MARK: - Blocks drawn by the layout manager

extension NSTextBlock {
    /// The layout manager hands over a frame that still includes the margins.
    func inner(_ frame: NSRect) -> NSRect {
        let top = width(for: .margin, edge: .minY), bottom = width(for: .margin, edge: .maxY)
        let left = width(for: .margin, edge: .minX), right = width(for: .margin, edge: .maxX)
        return NSRect(x: frame.minX + left, y: frame.minY + top,
                      width: frame.width - left - right, height: frame.height - top - bottom)
    }
}

final class CodeBlock: NSTextBlock {
    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        Theme.codeBackground.setFill()
        NSBezierPath(roundedRect: inner(frame), xRadius: 8, yRadius: 8).fill()
    }
}

final class QuoteBlock: NSTextBlock {
    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        Theme.quoteBar.setFill()
        let frame = inner(frame)
        let bar = NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height)
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class RuleBlock: NSTextBlock {
    override func drawBackground(withFrame frame: NSRect, in view: NSView?, characterRange: NSRange, layoutManager: NSLayoutManager) {
        Theme.hairline.setFill()
        let frame = inner(frame)
        NSRect(x: frame.minX, y: frame.midY.rounded(), width: frame.width, height: 1).fill()
    }
}

// MARK: - Images

final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()
    static let didLoad = Notification.Name("ImageStoreDidLoad")

    private let cache = NSCache<NSURL, NSImage>()
    private let lock = NSLock()
    private var requested = Set<URL>()

    /// Local files load immediately; remote ones arrive later and post `didLoad`.
    func image(for url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }

        if url.isFileURL {
            guard let image = NSImage(contentsOf: url) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        }

        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        lock.lock()
        let isNew = requested.insert(url).inserted
        lock.unlock()
        guard isNew else { return nil }

        URLSession.shared.dataTask(with: url) { [cache] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            cache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: ImageStore.didLoad, object: nil)
            }
        }.resume()
        return nil
    }
}

// MARK: - Renderer

enum MarkdownRenderer {
    private typealias Run = AttributedString.Runs.Run

    private struct State {
        let source: AttributedString
        let baseURL: URL?
        let text: NSString
        let lineStarts: [Int]

        /// UTF-16 offset for the parser's 1-based line and UTF-8 column.
        func offset(line: Int, column: Int) -> Int? {
            guard line >= 1, line <= lineStarts.count else { return nil }
            var index = lineStarts[line - 1]
            var bytes = 0
            while bytes < column - 1, index < text.length {
                let unit = text.character(at: index)
                if unit < 0x80 { bytes += 1; index += 1 }
                else if unit < 0x800 { bytes += 2; index += 1 }
                else if unit >= 0xD800, unit < 0xDC00 { bytes += 4; index += 2 }
                else { bytes += 3; index += 1 }
            }
            return index
        }

        /// Where `string` sits in the source, if it appears there unchanged.
        func verbatim(_ string: String, line: Int, column: Int) -> Int? {
            let length = (string as NSString).length
            guard length > 0, let start = offset(line: line, column: column),
                  start + length <= text.length,
                  text.substring(with: NSRange(location: start, length: length)) == string else { return nil }
            return start
        }
        var quotes: [Int: QuoteBlock] = [:]
        var tables: [Int: NSTextTable] = [:]
        var seenItems = Set<Int>()
        var previousWasList = false
        var previousWasTable = false
    }

    static func render(_ markdown: String, baseURL: URL?) -> NSAttributedString {
        let (placeholderMarkdown, mathSpans) = extractMathSpans(markdown)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true
        )
        guard let parsed = try? AttributedString(markdown: placeholderMarkdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: Theme.font(Theme.bodySize),
                .foregroundColor: NSColor.labelColor,
            ])
        }

        let output = NSMutableAttributedString()
        let text = placeholderMarkdown as NSString
        var lineStarts: [Int] = []
        var cursor = 0
        while cursor < text.length {
            lineStarts.append(cursor)
            var end = 0
            text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: cursor, length: 0))
            cursor = max(end, cursor + 1)
        }
        var state = State(source: parsed, baseURL: baseURL, text: text, lineStarts: lineStarts)

        // Consecutive runs with the same presentation intent form one block.
        var block: [Run] = []
        var intent: PresentationIntent?
        for run in parsed.runs {
            if !block.isEmpty, run.presentationIntent != intent {
                append(block, intent: intent, to: output, state: &state)
                block.removeAll(keepingCapacity: true)
            }
            intent = run.presentationIntent
            block.append(run)
        }
        if !block.isEmpty {
            append(block, intent: intent, to: output, state: &state)
        }
        replaceMathPlaceholders(in: output, spans: mathSpans)
        return output
    }

    // MARK: Math spans

    /// `$...$` and `$$...$$` (pandoc's rules: no space just inside the
    /// delimiters, a closing `$` isn't followed by a digit, `\$` escapes,
    /// never recognized inside code spans or fenced code blocks), plus
    /// ` ```math ` fenced blocks (handled separately, in `append`). Each span
    /// is replaced with the same number of U+E000 placeholder characters so
    /// line/column source positions stay valid for the rest of the document;
    /// `replaceMathPlaceholders` swaps the placeholder runs back for real
    /// math attachments once the normal markdown pass has run.
    private struct MathSpan { var raw: String; var display: Bool; var offset: Int }

    private static func extractMathSpans(_ markdown: String) -> (String, [MathSpan]) {
        var out = Array(markdown.utf16)
        let text = out
        var spans: [MathSpan] = []
        var i = 0
        var inFence = false

        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        while i < text.count {
            let c = text[i]

            if i == 0 || text[i - 1] == 0x0A {
                var j = i
                while j < text.count, text[j] == 0x20 { j += 1 }
                if j + 2 < text.count,
                   (text[j] == 0x60 && text[j + 1] == 0x60 && text[j + 2] == 0x60) ||
                   (text[j] == 0x7E && text[j + 1] == 0x7E && text[j + 2] == 0x7E) {
                    inFence.toggle()
                }
            }
            if inFence { i += 1; continue }

            if c == 0x60 {
                var tickCount = 0
                var j = i
                while j < text.count, text[j] == 0x60 { tickCount += 1; j += 1 }
                var k = j
                var closed = false
                while k < text.count {
                    if text[k] == 0x60 {
                        var m = k, count2 = 0
                        while m < text.count, text[m] == 0x60 { count2 += 1; m += 1 }
                        if count2 == tickCount { i = m; closed = true; break }
                        k = m
                    } else { k += 1 }
                }
                if !closed { i = j }
                continue
            }

            if c == 0x5C, i + 1 < text.count { i += 2; continue }

            if c == 0x24 {
                let isDisplay = i + 1 < text.count && text[i + 1] == 0x24
                if isDisplay {
                    var j = i + 2
                    var closing = -1
                    while j + 1 < text.count {
                        if text[j] == 0x24, text[j + 1] == 0x24 { closing = j; break }
                        if text[j] == 0x0A, j + 1 < text.count, text[j + 1] == 0x0A { break }
                        j += 1
                    }
                    if closing > i + 2 {
                        let raw = String(utf16CodeUnits: Array(text[(i + 2)..<closing]), count: closing - (i + 2))
                        if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            spans.append(MathSpan(raw: raw, display: true, offset: i))
                            for k in i..<(closing + 2) { out[k] = 0xE000 }
                            i = closing + 2
                            continue
                        }
                    }
                    i += 2
                    continue
                }
                guard i + 1 < text.count, !isSpace(text[i + 1]), text[i + 1] != 0x24 else { i += 1; continue }
                var j = i + 1
                var closing = -1
                while j < text.count {
                    if text[j] == 0x24, !isSpace(text[j - 1]) {
                        let after = j + 1 < text.count ? text[j + 1] : 0
                        if !isDigit(after) { closing = j; break }
                    }
                    if text[j] == 0x0A, j + 1 < text.count, text[j + 1] == 0x0A { break }
                    j += 1
                }
                if closing > i {
                    let raw = String(utf16CodeUnits: Array(text[(i + 1)..<closing]), count: closing - (i + 1))
                    spans.append(MathSpan(raw: raw, display: false, offset: i))
                    for k in i...closing { out[k] = 0xE000 }
                    i = closing + 1
                    continue
                }
                i += 1
                continue
            }
            i += 1
        }
        return (String(utf16CodeUnits: out, count: out.count), spans)
    }

    private static func replaceMathPlaceholders(in output: NSMutableAttributedString, spans: [MathSpan]) {
        guard !spans.isEmpty else { return }
        let text = output.string as NSString
        var spanIndex = 0
        var searchStart = 0
        var replacements: [(NSRange, NSAttributedString)] = []
        while spanIndex < spans.count, searchStart < text.length {
            var start = -1
            var idx = searchStart
            while idx < text.length {
                if text.character(at: idx) == 0xE000 {
                    if start == -1 { start = idx }
                } else if start != -1 {
                    break
                }
                idx += 1
            }
            guard start != -1 else { break }
            let range = NSRange(location: start, length: idx - start)
            let span = spans[spanIndex]
            let attachment = MathRenderer.render(span.raw, fontSize: span.display ? Theme.bodySize + 2 : Theme.bodySize, display: span.display)
            let replacement = NSMutableAttributedString(attributedString: attachment)
            let full = NSRange(location: 0, length: replacement.length)
            replacement.addAttribute(.marginAnchor, value: span.offset, range: full)
            // Carry over the placeholder's own paragraph style (and any table
            // block it belongs to) — the replacement has none of its own, and
            // without it an attachment inside a table cell lays out outside
            // the cell entirely.
            if let paragraphStyle = output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) {
                replacement.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
            }
            replacements.append((range, replacement))
            spanIndex += 1
            searchStart = idx
        }
        for (range, replacement) in replacements.reversed() {
            output.replaceCharacters(in: range, with: replacement)
        }
    }

    // MARK: Blocks

    private static func append(_ runs: [Run], intent: PresentationIntent?, to output: NSMutableAttributedString, state: inout State) {
        let components = intent?.components ?? []

        var headingLevel: Int?
        var isCode = false
        var codeLanguage: String?
        var isRule = false
        var quoteID: Int?
        var listDepth = 0
        var item: (id: Int, ordinal: Int, ordered: Bool)?
        var tableID: Int?
        var columns: [PresentationIntent.TableColumn] = []
        var row = 0
        var isHeaderRow = false
        var column = 0

        for (index, component) in components.enumerated() {
            switch component.kind {
            case .header(let level): headingLevel = level
            case .codeBlock(let language): isCode = true; codeLanguage = language
            case .thematicBreak: isRule = true
            case .blockQuote: quoteID = component.identity
            case .orderedList, .unorderedList: listDepth += 1
            case .listItem(let ordinal):
                guard item == nil else { break }
                var ordered = false
                if index + 1 < components.count, case .orderedList = components[index + 1].kind { ordered = true }
                item = (component.identity, ordinal, ordered)
            case .table(let cols): tableID = component.identity; columns = cols
            case .tableHeaderRow: isHeaderRow = true; row = 0
            case .tableRow(let index): row = index
            case .tableCell(let index): column = index
            default: break
            }
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 12
        var blocks: [NSTextBlock] = []

        if let quoteID {
            let quote = state.quotes[quoteID] ?? {
                let block = QuoteBlock()
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(16, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                state.quotes[quoteID] = block
                return block
            }()
            blocks.append(quote)
        }

        var text: NSMutableAttributedString
        let isList = item != nil

        if isRule {
            let rule = RuleBlock()
            rule.setContentWidth(100, type: .percentageValueType)
            rule.setWidth(10, type: .absoluteValueType, for: .margin, edge: .minY)
            rule.setWidth(22, type: .absoluteValueType, for: .margin, edge: .maxY)
            blocks.append(rule)
            style.lineSpacing = 0
            style.paragraphSpacing = 0
            text = NSMutableAttributedString(string: "\u{00A0}", attributes: [.font: Theme.font(2)])
        } else if isCode, codeLanguage?.lowercased() == "math" {
            var raw = runs.map { String(state.source[$0.range].characters) }.joined()
            while raw.hasSuffix("\n") { raw.removeLast() }
            let attachment = MathRenderer.render(raw, fontSize: Theme.bodySize + 2, display: true)
            text = NSMutableAttributedString(attributedString: attachment)
            if let position = runs.first?.markdownSourcePosition,
               let start = state.offset(line: position.startLine + 1, column: 1) {
                text.addAttribute(.marginAnchor, value: start, range: NSRange(location: 0, length: text.length))
            }
            style.alignment = .center
            style.lineSpacing = 0
            style.paragraphSpacing = 14
        } else if isCode {
            let code = CodeBlock()
            code.setContentWidth(100, type: .percentageValueType)
            code.setWidth(14, type: .absoluteValueType, for: .padding)
            code.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
            blocks.append(code)
            style.lineSpacing = 3
            style.paragraphSpacing = 0
            var raw = runs.map { String(state.source[$0.range].characters) }.joined()
            while raw.hasSuffix("\n") { raw.removeLast() }
            text = NSMutableAttributedString(string: raw, attributes: [
                .font: Theme.font(13, mono: true),
                .foregroundColor: NSColor.labelColor,
            ])
            // Fenced code starts on the line after the opening fence.
            if let position = runs.first?.markdownSourcePosition,
               let start = state.verbatim(raw, line: position.startLine + 1, column: 1) {
                text.addAttribute(.marginSource, value: start, range: NSRange(location: 0, length: text.length))
            }
        } else if let level = headingLevel {
            let size = Theme.headingSizes[min(max(level, 1), 6) - 1]
            let font = Theme.font(size, weight: level <= 2 ? .bold : .semibold)
            text = inline(runs, font: font, color: level == 6 ? .secondaryLabelColor : .labelColor, state: state)
            // Large type gets tighter tracking and leading.
            if size >= 19 {
                text.addAttribute(.kern, value: -0.008 * size, range: NSRange(location: 0, length: text.length))
            }
            style.lineSpacing = 2
            style.paragraphSpacing = size >= 19 ? 10 : 6
            style.paragraphSpacingBefore = output.length == 0 ? 0 : (size >= 19 ? 18 : 12)
        } else if let tableID {
            let table = state.tables[tableID] ?? {
                let table = NSTextTable()
                table.numberOfColumns = max(columns.count, 1)
                table.collapsesBorders = true
                table.hidesEmptyCells = false
                state.tables[tableID] = table
                return table
            }()
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setBorderColor(Theme.hairline)
            cell.setWidth(1, type: .absoluteValueType, for: .border)
            cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
            cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
            cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
            if isHeaderRow { cell.backgroundColor = Theme.codeBackground }
            blocks.append(cell)

            if column < columns.count {
                switch columns[column].alignment {
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                default: style.alignment = .left
                }
            }
            style.lineSpacing = 2
            style.paragraphSpacing = 0
            let font = Theme.font(14, weight: isHeaderRow ? .semibold : .regular)
            text = inline(runs, font: font, color: .labelColor, state: state)
        } else {
            let color: NSColor = quoteID != nil ? .secondaryLabelColor : .labelColor
            text = inline(runs, font: Theme.font(Theme.bodySize), color: color, state: state)
        }

        if let item, !isCode, tableID == nil {
            let indent: CGFloat = 26
            let head = indent * CGFloat(listDepth)
            style.headIndent = head
            style.tabStops = [NSTextTab(textAlignment: .left, location: head)]
            style.paragraphSpacing = 5

            if state.seenItems.insert(item.id).inserted {
                var marker = item.ordered ? "\(item.ordinal)." : (listDepth == 1 ? "•" : "◦")
                var markerColor = NSColor.tertiaryLabelColor

                // GitHub-style task items arrive as plain "[ ] " text.
                let plain = text.string
                if plain.hasPrefix("[ ] ") || plain.hasPrefix("[x] ") || plain.hasPrefix("[X] ") {
                    let done = !plain.hasPrefix("[ ] ")
                    marker = done ? "☑" : "☐"
                    markerColor = done ? .controlAccentColor : .secondaryLabelColor
                    text.deleteCharacters(in: NSRange(location: 0, length: 4))
                    var first = NSRange()
                    if text.length > 0,
                       let start = text.attribute(.marginSource, at: 0, longestEffectiveRange: &first, in: NSRange(location: 0, length: text.length)) as? Int {
                        text.addAttribute(.marginSource, value: start + 4, range: first)
                    }
                }

                style.firstLineHeadIndent = head - indent + 6
                let prefix = NSAttributedString(string: marker + "\t", attributes: [
                    .font: Theme.font(Theme.bodySize),
                    .foregroundColor: markerColor,
                ])
                text.insert(prefix, at: 0)
            } else {
                style.firstLineHeadIndent = head
            }
        } else if state.previousWasList, style.paragraphSpacingBefore < 8, tableID == nil {
            style.paragraphSpacingBefore = 8
        }
        if state.previousWasTable, tableID == nil {
            style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 16)
        }
        state.previousWasList = isList
        state.previousWasTable = tableID != nil

        style.textBlocks = blocks
        text.append(NSAttributedString(string: "\n", attributes: text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        output.append(text)
    }

    // MARK: Inline content

    private static func inline(_ runs: [Run], font: NSFont, color: NSColor, state: State) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let size = font.pointSize
        let baseWeight = fontWeight(of: font)

        for run in runs {
            let intents = run.inlinePresentationIntent ?? []
            var string = String(state.source[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]

            if let source = run.imageURL {
                if let url = resolve(source, baseURL: state.baseURL), let image = ImageStore.shared.image(for: url) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let scale = min(1, 640 / max(image.size.width, 1))
                    attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                    result.append(NSAttributedString(attachment: attachment))
                    continue
                }
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                if string.isEmpty { string = source.lastPathComponent }
            }

            if intents.contains(.softBreak) { string = " " }
            if intents.contains(.lineBreak) { string = "\u{2028}" }

            let isCode = intents.contains(.code) || intents.contains(.inlineHTML) || intents.contains(.blockHTML)
            if intents.contains(.blockHTML) {
                while string.hasSuffix("\n") { string.removeLast() }
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            let strong = intents.contains(.stronglyEmphasized)
            attributes[.font] = Theme.font(
                isCode ? size * 0.9 : size,
                weight: strong && baseWeight.rawValue < NSFont.Weight.semibold.rawValue ? .semibold : baseWeight,
                italic: intents.contains(.emphasized),
                mono: isCode
            )
            if intents.contains(.code) {
                attributes[.backgroundColor] = Theme.codeBackground
            }
            if intents.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if run.imageURL == nil, let position = run.markdownSourcePosition,
               let start = state.verbatim(string, line: position.startLine, column: position.startColumn) {
                attributes[.marginSource] = start
            }
            if let link = run.link, run.imageURL == nil {
                attributes[.link] = resolve(link, baseURL: state.baseURL) ?? link
            }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }

    private static func fontWeight(of font: NSFont) -> NSFont.Weight {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let value = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        return NSFont.Weight(rawValue: CGFloat(value))
    }

    private static func resolve(_ url: URL, baseURL: URL?) -> URL? {
        if url.scheme != nil { return url }
        guard let baseURL else { return nil }
        let path = url.relativeString.removingPercentEncoding ?? url.relativeString
        if path.hasPrefix("#") { return nil }
        return URL(fileURLWithPath: path, relativeTo: baseURL).absoluteURL
    }
}
