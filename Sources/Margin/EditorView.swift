import AppKit
import SwiftUI

// MARK: - Shared text view with a centred reading column

class CenteredTextView: NSTextView {
    static let columnWidth: CGFloat = 720

    var link: PaneLink?
    var pane = PaneLink.Pane.editor
    var kind = DocKind.markdown

    /// Character whose line gets the "you are here" highlight.
    var highlightIndex: Int? {
        didSet { if highlightIndex != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLineHighlight()
        super.draw(dirtyRect)
    }

    private func drawLineHighlight() {
        guard let index = highlightIndex, let layout = layoutManager else { return }
        var line = layout.extraLineFragmentRect
        if index < (string as NSString).length, layout.numberOfGlyphs > 0 {
            line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil)
        } else if line.height == 0, layout.numberOfGlyphs > 0 {
            line = layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil)
        }
        guard line.height > 0 else { return }
        let origin = textContainerOrigin
        let box = NSRect(x: origin.x + line.minX - 6, y: origin.y + line.minY, width: line.width + 12, height: line.height)
        Theme.lineHighlight.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
    }

    /// Option-click brings the other pane to the same place, locked or not.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.modifierFlags.contains(.option) {
            link?.follow(from: pane)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, ((newSize.width - Self.columnWidth) / 2).rounded(.down))
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: 28)
        }
    }
}

// MARK: - Editor

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    var isActive: Bool
    var kind: DocKind
    let link: PaneLink

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // TextKit 1 lays the whole document out, which gives the exact line
        // positions that locked scrolling needs.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true

        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false
        view.insertionPointColor = .controlAccentColor
        view.typingAttributes = Highlighter.base
        view.kind = kind

        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        // Text goes in after the view joins the scroll view, so it grows
        // downwards from the top rather than shifting its origin.
        scroll.documentView = view
        view.string = text
        context.coordinator.lastText = text
        link.editor = view
        view.link = link
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = scroll.documentView as? CenteredTextView else { return }
        if view.kind != kind {
            view.kind = kind
            Highlighter.highlight(view.textStorage ?? NSTextStorage(), edited: NSRange(location: 0, length: (view.string as NSString).length), kind: kind)
        }

        // Only external changes (revert, version restore) reach this branch.
        if text != coordinator.lastText {
            coordinator.lastText = text
            view.string = text
        }

        if isActive != coordinator.wasActive {
            coordinator.wasActive = isActive
            if isActive {
                let link = link
                DispatchQueue.main.async {
                    view.window?.makeFirstResponder(view)
                    link.selectionChanged(.editor)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: EditorView
        var lastText = ""
        var wasActive = false

        init(_ parent: EditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let string = view.string
            lastText = string
            parent.text = string
        }

        func textStorage(
            _ storage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            Highlighter.highlight(storage, edited: editedRange, kind: parent.kind)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.link.selectionChanged(.editor)
        }

        @objc func scrolled(_ notification: Notification) {
            parent.link.scrolled(.editor)
        }
    }
}

final class EditorTextView: CenteredTextView {
    // MARK: Formatting

    @objc func toggleBold(_ sender: Any?) {
        switch kind {
        case .markdown: toggle("**")
        case .latex: wrap(command: "textbf")
        case .json: NSSound.beep()
        }
    }
    @objc func toggleItalic(_ sender: Any?) {
        switch kind {
        case .markdown: toggle("*")
        case .latex: wrap(command: "emph")
        case .json: NSSound.beep()
        }
    }
    @objc func toggleCode(_ sender: Any?) {
        switch kind {
        case .markdown: toggle("`")
        case .latex: wrap(command: "texttt")
        case .json: NSSound.beep()
        }
    }

    @objc func insertLink(_ sender: Any?) {
        switch kind {
        case .markdown:
            let selection = selectedRange()
            let title = (string as NSString).substring(with: selection)
            insertText("[\(title)](url)", replacementRange: selection)
            if title.isEmpty {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            } else {
                // Select "url" so it can be typed over straight away.
                setSelectedRange(NSRange(location: selection.location + (title as NSString).length + 3, length: 3))
            }
        case .latex:
            let selection = selectedRange()
            let title = (string as NSString).substring(with: selection)
            let prefix = "\\href{url}{"
            insertText("\(prefix)\(title)}", replacementRange: selection)
            if title.isEmpty {
                setSelectedRange(NSRange(location: selection.location + (prefix as NSString).length, length: 0))
            } else {
                // Select "url" so it can be typed over straight away.
                setSelectedRange(NSRange(location: selection.location + 6, length: 3))
            }
        case .json:
            NSSound.beep()
        }
    }

    /// JSON's one formatting command: re-indent, keeping key order and literal spelling.
    @objc func formatJSON(_ sender: Any?) {
        guard kind == .json, let formatted = JSONRenderer.format(string), formatted != string else {
            NSSound.beep()
            return
        }
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: formatted) else { return }
        textStorage?.replaceCharacters(in: full, with: formatted)
        didChangeText()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func wrap(command: String) {
        let text = string as NSString
        let selection = selectedRange()
        let inner = text.substring(with: selection)
        let prefix = "\\\(command){"
        insertText(prefix + inner + "}", replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + (prefix as NSString).length, length: inner.utf16.count))
    }

    private func toggle(_ marker: String) {
        let text = string as NSString
        let selection = selectedRange()
        let length = (marker as NSString).length
        let outer = NSRange(location: selection.location - length, length: selection.length + length * 2)

        // Already wrapped: take the markers off again.
        if outer.location >= 0, NSMaxRange(outer) <= text.length {
            let before = text.substring(with: NSRange(location: outer.location, length: length))
            let after = text.substring(with: NSRange(location: NSMaxRange(selection), length: length))
            if before == marker, after == marker {
                let inner = text.substring(with: selection)
                insertText(inner, replacementRange: outer)
                setSelectedRange(NSRange(location: outer.location, length: selection.length))
                return
            }
        }

        let inner = text.substring(with: selection)
        insertText(marker + inner + marker, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + length, length: selection.length))
    }

    // MARK: List continuation

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))[ \t]+(\[[ xX]\][ \t]+)?"#
    )
    private static let itemPrefix = try! NSRegularExpression(pattern: #"^([ \t]*)\\item\b[ \t]*"#)

    override func insertNewline(_ sender: Any?) {
        if kind == .latex {
            insertNewlineLaTeX(sender)
            return
        }
        let text = string as NSString
        let selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let head = NSRange(location: line.location, length: selection.location - line.location)

        guard selection.length == 0,
              let match = Self.listPrefix.firstMatch(in: string, options: .anchored, range: head) else {
            super.insertNewline(sender)
            return
        }

        // Return on an empty item ends the list.
        let content = text.substring(with: NSRange(location: NSMaxRange(match.range), length: NSMaxRange(line) - NSMaxRange(match.range)))
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText("", replacementRange: NSRange(location: line.location, length: selection.location - line.location))
            return
        }

        var next = text.substring(with: match.range(at: 1))
        if match.range(at: 2).location != NSNotFound {
            next += text.substring(with: match.range(at: 2))
        } else {
            let number = Int(text.substring(with: match.range(at: 3))) ?? 0
            next += "\(number + 1)" + text.substring(with: match.range(at: 4))
        }
        next += " "
        if match.range(at: 5).location != NSNotFound { next += "[ ] " }
        insertText("\n" + next, replacementRange: selection)
    }

    /// Continues `\item ` onto the next line while inside a LaTeX list; Return
    /// on an empty item just ends it, same spirit as the markdown case above.
    private func insertNewlineLaTeX(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let head = NSRange(location: line.location, length: selection.location - line.location)

        guard selection.length == 0,
              let match = Self.itemPrefix.firstMatch(in: string, options: .anchored, range: head) else {
            super.insertNewline(sender)
            return
        }

        let content = text.substring(with: NSRange(location: NSMaxRange(match.range), length: NSMaxRange(line) - NSMaxRange(match.range)))
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText("", replacementRange: NSRange(location: line.location, length: selection.location - line.location))
            return
        }

        let indent = text.substring(with: match.range(at: 1))
        insertText("\n\(indent)\\item ", replacementRange: selection)
    }
}

// MARK: - Source highlighting

enum Highlighter {
    static let size: CGFloat = 14
    static let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    static let italic: NSFont = {
        let descriptor = regular.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? regular
    }()

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        return style
    }()

    static let base: [NSAttributedString.Key: Any] = [
        .font: regular,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let fence = regex(#"^ {0,3}(```|~~~)"#)
    private static let anyFence = try! NSRegularExpression(pattern: #"^ {0,3}(```|~~~)"#, options: .anchorsMatchLines)
    private static let heading = regex(#"^#{1,6}[ \t]"#)
    private static let quote = regex(#"^[ \t]*>"#)
    private static let listMarker = regex(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]"#)
    private static let code = regex(#"`[^`\n]+`"#)
    private static let strong = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = regex(#"(?<![\*_\w])([\*_])(?=\S)([^\*_\n]+?)(?<=\S)\1(?![\*_\w])"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)

    static func highlight(_ storage: NSTextStorage, edited: NSRange, kind: DocKind) {
        switch kind {
        case .markdown: highlightMarkdown(storage, edited: edited)
        case .json: highlightJSON(storage, edited: edited)
        case .latex: highlightLaTeX(storage, edited: edited)
        }
    }

    /// Whole-document pass for normal files; edited lines only for very large ones.
    private static func highlightMarkdown(_ storage: NSTextStorage, edited: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }

        var range = NSRange(location: 0, length: text.length)
        var inFence = false
        if text.length > 200_000 {
            range = text.paragraphRange(for: edited)
            let before = NSRange(location: 0, length: range.location)
            inFence = anyFence.numberOfMatches(in: storage.string, range: before) % 2 == 1
        }

        let string = storage.string
        storage.setAttributes(base, range: range)

        text.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            guard line.length > 0 else { return }

            if fence.firstMatch(in: string, options: .anchored, range: line) != nil {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line)
                return
            }
            if inFence {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
                return
            }

            if let match = heading.firstMatch(in: string, options: .anchored, range: line) {
                storage.addAttribute(.font, value: bold, range: line)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range)
                return
            }
            if quote.firstMatch(in: string, options: .anchored, range: line) != nil {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
            }
            if let match = listMarker.firstMatch(in: string, options: .anchored, range: line) {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
            }

            strong.enumerateMatches(in: string, range: line) { match, _, _ in
                if let match { storage.addAttribute(.font, value: bold, range: match.range) }
            }
            emphasis.enumerateMatches(in: string, range: line) { match, _, _ in
                if let match { storage.addAttribute(.font, value: italic, range: match.range) }
            }
            link.enumerateMatches(in: string, range: line) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range(at: 1))
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range(at: 2))
            }
            code.enumerateMatches(in: string, range: line) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.font, value: regular, range: match.range)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
            }
        }
    }

    // MARK: JSON

    private static let jsonKey = regex(#""(?:[^"\\]|\\.)*"\s*(?=:)"#)
    private static let jsonString = regex(#""(?:[^"\\]|\\.)*""#)
    private static let jsonNumber = regex(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#)
    private static let jsonLiteral = regex(#"\b(true|false|null)\b"#)
    private static let jsonPunct = regex(#"[{}\[\],:]"#)

    private static func highlightJSON(_ storage: NSTextStorage, edited: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        var range = NSRange(location: 0, length: text.length)
        if text.length > 200_000 { range = text.paragraphRange(for: edited) }
        let string = storage.string
        storage.setAttributes(base, range: range)

        var stringRanges: [NSRange] = []
        jsonString.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            stringRanges.append(match.range)
        }
        func outsideStrings(_ r: NSRange) -> Bool {
            !stringRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        jsonNumber.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match, outsideStrings(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: match.range)
        }
        jsonLiteral.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match, outsideStrings(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
        }
        jsonPunct.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match, outsideStrings(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range)
        }
        jsonKey.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
            storage.addAttribute(.font, value: bold, range: match.range)
        }
    }

    // MARK: LaTeX

    private static let latexComment = try! NSRegularExpression(pattern: #"(?<!\\)%.*$"#, options: [.anchorsMatchLines])
    private static let latexCommand = regex(#"\\[a-zA-Z]+\*?"#)
    private static let latexSection = try! NSRegularExpression(
        pattern: #"^\s*\\(chapter|section|subsection|subsubsection|paragraph)\*?\{"#, options: [.anchorsMatchLines]
    )
    private static let latexMathDisplay = regex(#"\$\$[\s\S]*?\$\$"#)
    private static let latexMathInline = regex(#"(?<!\\)\$(?:[^$\\\n]|\\.)+\$"#)

    private static func highlightLaTeX(_ storage: NSTextStorage, edited: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        var range = NSRange(location: 0, length: text.length)
        if text.length > 200_000 { range = text.paragraphRange(for: edited) }
        let string = storage.string
        storage.setAttributes(base, range: range)

        latexMathDisplay.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: match.range)
        }
        latexMathInline.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: match.range)
        }
        latexCommand.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
        }
        latexSection.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            let line = text.lineRange(for: match.range)
            storage.addAttribute(.font, value: bold, range: line)
        }
        latexComment.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range)
        }
    }
}
