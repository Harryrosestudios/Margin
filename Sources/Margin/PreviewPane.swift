import AppKit
import SwiftUI

/// One render of the document, with the source it came from.
struct Rendered {
    var string = NSAttributedString()
    var source = ""
    var token = 0
}

struct PreviewView: NSViewRepresentable {
    var content: Rendered
    var baseURL: URL?
    var isActive: Bool
    var kind: DocKind
    let link: PaneLink

    func makeCoordinator() -> Coordinator { Coordinator(link: link) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // TextKit 1: tables and block backgrounds are drawn by NSTextBlock.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let view = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.drawsBackground = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .cursor: NSCursor.pointingHand,
        ]

        // Editable, but every change is routed to the markdown source.
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.importsGraphics = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.insertionPointColor = .controlAccentColor
        view.link = link
        view.pane = .preview
        view.kind = kind
        view.delegate = context.coordinator

        scroll.documentView = view
        link.preview = view
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
        guard let view = scroll.documentView as? CenteredTextView else { return }
        let coordinator = context.coordinator
        coordinator.baseURL = baseURL
        coordinator.kind = kind
        view.kind = kind

        // Skip renders the preview already produced itself after an edit.
        let alreadyShown = content.source == link.renderedSource && content.token == coordinator.token
        if content.string !== coordinator.shown, !(alreadyShown && coordinator.shown != nil) {
            coordinator.show(content.string, source: content.source, in: view)
        }
        coordinator.shown = content.string
        coordinator.token = content.token

        if isActive != coordinator.wasActive {
            coordinator.wasActive = isActive
            if isActive {
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let link: PaneLink
        var shown: NSAttributedString?
        var token = 0
        var baseURL: URL?
        var kind = DocKind.markdown
        var wasActive = false

        init(link: PaneLink) { self.link = link }

        func show(_ string: NSAttributedString, source: String, in view: NSTextView, caret: Int? = nil) {
            let location = caret ?? view.selectedRange().location
            link.quietly {
                view.textStorage?.setAttributedString(string)
                view.setSelectedRange(NSRange(location: min(location, string.length), length: 0))
            }
            link.renderedSource = source
            link.rebuildAnchors()
            link.refreshHighlight()
            if view.window?.firstResponder !== view {
                link.scrolled(.editor)
            }
        }

        /// Typing in the preview edits the markdown source instead, then re-renders.
        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString,
                  let editor = link.editor,
                  let storage = view.textStorage,
                  editor.string == link.renderedSource,
                  !replacement.contains(where: \.isNewline),
                  let target = link.sourceRange(forRendered: range, in: storage) else {
                NSSound.beep()
                return false
            }

            // Edit the source in place (undoable, and without scrolling the editor).
            guard editor.shouldChangeText(in: target, replacementString: replacement) else { return false }
            link.quietly {
                editor.textStorage?.replaceCharacters(in: target, with: replacement)
                editor.didChangeText()
                editor.setSelectedRange(NSRange(location: target.location + (replacement as NSString).length, length: 0))
            }

            let source = editor.string
            let string = kind.render(source, baseURL: baseURL)
            show(string, source: source, in: view, caret: range.location + (replacement as NSString).length)
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            link.selectionChanged(.preview)
        }

        @objc func scrolled(_ notification: Notification) {
            link.scrolled(.preview)
        }
    }
}

final class PreviewTextView: CenteredTextView {
    @objc func toggleBold(_ sender: Any?) { format(#selector(EditorTextView.toggleBold(_:))) }
    @objc func toggleItalic(_ sender: Any?) { format(#selector(EditorTextView.toggleItalic(_:))) }
    @objc func toggleCode(_ sender: Any?) { format(#selector(EditorTextView.toggleCode(_:))) }

    /// Applies a formatting command to the selected words in the source.
    private func format(_ action: Selector) {
        guard let link, let editor = link.editor, let storage = textStorage,
              editor.string == link.renderedSource,
              selectedRange().length > 0,
              let range = link.sourceRange(forRendered: selectedRange(), in: storage) else {
            NSSound.beep()
            return
        }
        link.quietly { editor.setSelectedRange(range) }
        editor.perform(action, with: nil)
    }
}
