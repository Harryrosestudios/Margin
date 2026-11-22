import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @SceneStorage("viewMode") private var mode: ViewMode = .split
    @AppStorage("lockPanes") private var lock = true
    @State private var rendered = Rendered()
    @State private var subtitle = ""
    @State private var imageToken = 0
    @State private var link = PaneLink()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: DocKind { DocKind(url: fileURL) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let half = (width / 2).rounded()

            ZStack(alignment: .topLeading) {
                // Each pane leaves along the edge it came in from.
                EditorView(text: $document.text, isActive: mode != .preview, kind: kind, link: link)
                    .frame(width: mode == .edit ? width : half)
                    .offset(x: mode == .preview ? -half : 0)
                    .opacity(mode == .preview ? 0 : 1)
                    .allowsHitTesting(mode != .preview)

                PreviewView(content: rendered, baseURL: baseURL, isActive: mode == .preview, kind: kind, link: link)
                    .frame(width: mode == .preview ? width : width - half)
                    .offset(x: mode == .preview ? 0 : (mode == .split ? half : width))
                    .opacity(mode == .edit ? 0 : 1)
                    .allowsHitTesting(mode != .edit)

                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                    .offset(x: half)
                    .opacity(mode == .split ? 1 : 0)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1), value: mode)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $lock) {
                    Label("Lock Panes", systemImage: lock ? "lock" : "lock.open")
                }
                .disabled(mode != .split)
                .help("Keep both sides aligned when you scroll or click (⌘L). Option-click works without it.")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Editor ⌘1 · Split ⌘2 · Preview ⌘3")
            }
        }
        .focusedSceneValue(\.viewMode, $mode)
        .onChange(of: lock && mode == .split, initial: true) { _, new in link.locked = new }
        .onReceive(NotificationCenter.default.publisher(for: ImageStore.didLoad)) { _ in imageToken += 1 }
        .task(id: RenderKey(text: document.text, token: imageToken, visible: mode != .edit)) {
            await render()
        }
    }

    private var baseURL: URL? { fileURL?.deletingLastPathComponent() }

    private func render() async {
        // Coalesce bursts of typing: superseded tasks are cancelled here.
        try? await Task.sleep(for: .milliseconds(12))
        if Task.isCancelled { return }

        let text = document.text
        let base = baseURL
        let token = imageToken
        let visible = mode != .edit
        let kind = kind

        let result = await Task.detached(priority: .userInitiated) {
            let count = kind.count(text)
            let string = visible ? kind.render(text, baseURL: base) : nil
            return RenderResult(string: string, subtitle: count)
        }.value

        if Task.isCancelled { return }
        subtitle = result.subtitle
        if let string = result.string { rendered = Rendered(string: string, source: text, token: token) }
    }
}

private struct RenderKey: Equatable {
    let text: String
    let token: Int
    let visible: Bool
}

private struct RenderResult: @unchecked Sendable {
    let string: NSAttributedString?
    let subtitle: String
}
