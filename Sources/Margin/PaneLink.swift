import AppKit

extension NSAttributedString.Key {
    /// On rendered text that appears verbatim in the markdown source: the UTF-16
    /// offset in the source of the first character of the attribute run.
    static let marginSource = NSAttributedString.Key("MarginSource")
}

/// Connects the editor and the preview: maps positions between source and
/// rendered text, and keeps the two panes aligned while locked.
final class PaneLink {
    enum Pane { case editor, preview }

    weak var editor: NSTextView?
    weak var preview: NSTextView?

    /// The source text the preview currently shows.
    var renderedSource = ""

    var locked = false {
        didSet {
            guard locked, !oldValue else { return }
            reference = 0
            align(from: .editor)
        }
    }

    private var anchors: [(source: Int, rendered: Int)] = [(0, 0)]
    /// Distance below the top of each pane at which the two are kept aligned.
    private var reference: CGFloat = 0
    private var applying = false

    func quietly(_ work: () -> Void) {
        let was = applying
        applying = true
        work()
        applying = was
    }

    // MARK: Position mapping

    func rebuildAnchors() {
        guard let storage = preview?.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        // Both attributes carry a source offset as their value; .marginSource
        // marks rendered text that matches the source verbatim, .marginAnchor
        // marks rendered content (math, JSON punctuation, LaTeX accents, ...)
        // that only approximately stands for a place in the source. Either is
        // good enough to align scrolling and locked-pane clicks.
        var candidates: [(source: Int, rendered: Int)] = []
        storage.enumerateAttribute(.marginSource, in: full) { value, range, _ in
            guard let source = value as? Int else { return }
            candidates.append((source, range.location))
        }
        storage.enumerateAttribute(.marginAnchor, in: full) { value, range, _ in
            guard let source = value as? Int else { return }
            candidates.append((source, range.location))
        }
        candidates.sort { $0.rendered < $1.rendered }

        var list: [(source: Int, rendered: Int)] = [(0, 0)]
        for candidate in candidates {
            guard candidate.source > list[list.count - 1].source,
                  candidate.rendered > list[list.count - 1].rendered else { continue }
            list.append(candidate)
        }
        let end = max((renderedSource as NSString).length, list[list.count - 1].source)
        list.append((end, storage.length))
        anchors = list
    }

    private func anchorIndex(_ value: Int, _ key: ((source: Int, rendered: Int)) -> Int) -> Int {
        var low = 0, high = anchors.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if key(anchors[mid]) <= value { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func renderedIndex(forSource source: Int) -> Int {
        let index = anchorIndex(source, { $0.source })
        let anchor = anchors[index]
        let limit = index + 1 < anchors.count ? anchors[index + 1].rendered : anchor.rendered
        return min(anchor.rendered + (source - anchor.source), max(limit, anchor.rendered))
    }

    func sourceIndex(forRendered rendered: Int) -> Int {
        let index = anchorIndex(rendered, { $0.rendered })
        let anchor = anchors[index]
        let limit = index + 1 < anchors.count ? anchors[index + 1].source : anchor.source
        return min(anchor.source + (rendered - anchor.rendered), max(limit, anchor.source))
    }

    private func source(at index: Int, in storage: NSTextStorage) -> Int? {
        guard index >= 0, index < storage.length else { return nil }
        var run = NSRange()
        let full = NSRange(location: 0, length: storage.length)
        guard let start = storage.attribute(.marginSource, at: index, longestEffectiveRange: &run, in: full) as? Int else {
            return nil
        }
        return start + (index - run.location)
    }

    /// The source range behind a rendered range, or nil when the range touches
    /// anything that is not plain text in the source (markers, bullets, breaks).
    func sourceRange(forRendered range: NSRange, in storage: NSTextStorage) -> NSRange? {
        if range.length == 0 {
            if let before = source(at: range.location - 1, in: storage) {
                return NSRange(location: before + 1, length: 0)
            }
            if let after = source(at: range.location, in: storage) {
                return NSRange(location: after, length: 0)
            }
            return nil
        }
        guard let first = source(at: range.location, in: storage),
              let last = source(at: NSMaxRange(range) - 1, in: storage),
              last - first == range.length - 1 else { return nil }
        return NSRange(location: first, length: range.length)
    }

    // MARK: Current line

    private var lastPane = Pane.editor

    /// Highlights the insertion point's line in the active pane and the
    /// matching line in the other one.
    func refreshHighlight() {
        guard let editor = editor as? CenteredTextView, let preview = preview as? CenteredTextView else { return }
        let (from, to) = lastPane == .editor ? (editor, preview) : (preview, editor)
        let index = from.selectedRange().location
        let mapped = lastPane == .editor ? renderedIndex(forSource: index) : sourceIndex(forRendered: index)
        from.highlightIndex = index
        to.highlightIndex = min(mapped, (to.string as NSString).length)
    }

    // MARK: Locked panes

    func scrolled(_ pane: Pane) {
        guard locked, !applying else { return }
        align(from: pane)
    }

    /// A click sets the line both panes are aligned on, and moves the other
    /// pane's insertion point to the matching place.
    func selectionChanged(_ pane: Pane) {
        if !applying, let view = pane == .editor ? editor : preview, view.window?.firstResponder === view {
            lastPane = pane
            refreshHighlight()
        }
        guard locked, !applying, let editor, let preview else { return }
        let from = pane == .editor ? editor : preview
        guard from.window?.firstResponder === from,
              let type = NSApp.currentEvent?.type,
              type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else { return }
        follow(from: pane)
    }

    /// Moves the other pane so the insertion point's line sits at the same height in both.
    func follow(from pane: Pane) {
        guard let editor, let preview else { return }
        let (from, to) = pane == .editor ? (editor, preview) : (preview, editor)
        let index = from.selectedRange().location
        let mapped = pane == .editor ? renderedIndex(forSource: index) : sourceIndex(forRendered: index)
        let target = min(mapped, (to.string as NSString).length)

        if let y = y(of: index, in: from) {
            reference = max(0, y - top(of: from))
        }
        quietly { to.setSelectedRange(NSRange(location: target, length: 0)) }
        if let y = y(of: target, in: to) {
            scroll(to, to: y - reference)
        }
    }

    func align(from pane: Pane) {
        guard let editor, let preview, editor.window != nil, anchors.count > 1 else { return }
        let (from, to) = pane == .editor ? (editor, preview) : (preview, editor)
        let fromKey: ((source: Int, rendered: Int)) -> Int = pane == .editor ? { $0.source } : { $0.rendered }
        let toKey: ((source: Int, rendered: Int)) -> Int = pane == .editor ? { $0.rendered } : { $0.source }

        let line = top(of: from) + reference
        let index = from.characterIndexForInsertion(at: NSPoint(x: from.textContainerOrigin.x + 2, y: line))
        let low = anchorIndex(index, fromKey)
        guard let fromLow = y(of: fromKey(anchors[low]), in: from),
              let toLow = y(of: toKey(anchors[low]), in: to) else { return }

        var target = toLow + (line - fromLow)
        if line > fromLow {
            // Interpolate towards the next anchor that sits on a later line.
            var high = low + 1
            let stop = min(anchors.count, low + 200)
            while high < stop {
                if let fromHigh = y(of: fromKey(anchors[high]), in: from), fromHigh > fromLow + 0.5 {
                    if let toHigh = y(of: toKey(anchors[high]), in: to), toHigh >= toLow {
                        let fraction = min(1, (line - fromLow) / (fromHigh - fromLow))
                        target = toLow + fraction * (toHigh - toLow)
                    }
                    break
                }
                high += 1
            }
        }
        scroll(to, to: target - reference)
    }

    // MARK: Geometry

    private func top(of view: NSTextView) -> CGFloat {
        guard let scroll = view.enclosingScrollView else { return 0 }
        return scroll.contentView.bounds.origin.y + scroll.contentInsets.top
    }

    /// Top of the line holding `index`, in the text view's coordinates.
    private func y(of index: Int, in view: NSTextView) -> CGFloat? {
        let length = (view.string as NSString).length
        let index = min(max(index, 0), length)
        let origin = view.textContainerOrigin.y

        guard let layout = view.layoutManager, let container = view.textContainer else { return nil }
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return origin }
        if index >= length {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { return extra.minY + origin }
            return layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil).maxY + origin
        }
        let glyph = layout.glyphIndexForCharacter(at: index)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + origin
    }

    private func scroll(_ view: NSTextView, to top: CGFloat) {
        guard let scroll = view.enclosingScrollView else { return }
        let clip = scroll.contentView
        let lowest = -scroll.contentInsets.top
        let highest = max(lowest, view.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        let y = min(max(top - scroll.contentInsets.top, lowest), highest).rounded()
        guard abs(clip.bounds.origin.y - y) >= 0.5 else { return }
        quietly {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
