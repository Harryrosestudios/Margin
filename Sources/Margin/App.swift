import SwiftUI
import UniformTypeIdentifiers

@main
struct MarginApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            TextEditingCommands()
            MarginCommands()
        }
    }
}

// MARK: - Document

struct MarkdownDocument: FileDocument {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")
    static var readableContentTypes: [UTType] { [markdown, .json, DocKind.latexType, .plainText] }
    static var writableContentTypes: [UTType] { [markdown, .json, DocKind.latexType, .plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - View mode

enum ViewMode: String, CaseIterable, Identifiable {
    case edit, split, preview
    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Editor"
        case .split: "Split"
        case .preview: "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .edit: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}

struct ViewModeKey: FocusedValueKey {
    typealias Value = Binding<ViewMode>
}

extension FocusedValues {
    var viewMode: Binding<ViewMode>? {
        get { self[ViewModeKey.self] }
        set { self[ViewModeKey.self] = newValue }
    }
}

// MARK: - Menus

struct MarginCommands: Commands {
    @FocusedValue(\.viewMode) private var mode
    @AppStorage("lockPanes") private var lock = true

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { mode?.wrappedValue = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(mode == nil)
            }
            Toggle("Lock Panes", isOn: $lock)
                .keyboardShortcut("l")
            Divider()
        }
        CommandMenu("Format") {
            Button("Bold") { send(#selector(EditorTextView.toggleBold(_:))) }
                .keyboardShortcut("b")
            Button("Italic") { send(#selector(EditorTextView.toggleItalic(_:))) }
                .keyboardShortcut("i")
            Button("Code") { send(#selector(EditorTextView.toggleCode(_:))) }
                .keyboardShortcut("e")
            Button("Link") { send(#selector(EditorTextView.insertLink(_:))) }
                .keyboardShortcut("k")
            Divider()
            Button("Format JSON") { send(#selector(EditorTextView.formatJSON(_:))) }
        }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
