import AppKit
import UniformTypeIdentifiers

/// The kinds of file Margin edits. Picked from the file's extension; new
/// untitled documents are markdown until saved as something else.
enum DocKind: Equatable, Sendable {
    case markdown, json, latex

    static let markdownType = UTType(importedAs: "net.daringfireball.markdown")
    static let latexType = UTType(importedAs: "org.tug.tex", conformingTo: .plainText)

    init(url: URL?) {
        switch url?.pathExtension.lowercased() ?? "" {
        case "json", "geojson", "jsonc": self = .json
        case "tex", "latex", "ltx", "sty", "cls": self = .latex
        default: self = .markdown
        }
    }

    /// Renders source text for the preview pane.
    func render(_ text: String, baseURL: URL?) -> NSAttributedString {
        switch self {
        case .markdown: MarkdownRenderer.render(text, baseURL: baseURL)
        case .json: JSONRenderer.render(text)
        case .latex: LaTeXRenderer.render(text, baseURL: baseURL)
        }
    }

    /// Words for the title bar; JSON counts values instead.
    func count(_ text: String) -> String {
        if self == .json {
            let lines = text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            return lines == 1 ? "1 line" : "\(lines.formatted()) lines"
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return words == 1 ? "1 word" : "\(words.formatted()) words"
    }
}

extension NSAttributedString.Key {
    /// Like `marginSource`, but only for keeping the panes aligned: marks rendered
    /// content (math, bullets) that stands for source text without matching it.
    static let marginAnchor = NSAttributedString.Key("MarginAnchor")
}
