import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Renders a fenced code block with a language label and a copy button.
/// While streaming (`isComplete == false`) a subtle progress indicator shows.
/// When the theme provides a `codeHighlighter`, plain text renders first and
/// the highlighted version swaps in as it resolves (debounced mid-stream so
/// large blocks don't re-tokenize on every chunk).
struct CodeBlockView: View {
    let language: String?
    let code: String
    let isComplete: Bool

    @Environment(\.markdownTheme) private var theme
    @State private var didCopy = false
    @State private var highlighted: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !isComplete {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted ?? AttributedString(code))
                    .font(theme.codeFont)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: highlightTaskKey) {
            guard let highlighter = theme.codeHighlighter else { return }
            // Mid-stream, wait out further chunks before re-tokenizing; the
            // task(id:) cancellation makes this a trailing-edge debounce.
            if !isComplete {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            if let result = await highlighter(code, language), !Task.isCancelled {
                highlighted = result
            }
        }
    }

    // Re-highlight when the content grows, the block completes, or the theme
    // changes (via codeThemeKey — the highlighter closure itself can't be
    // compared).
    private var highlightTaskKey: String {
        "\(theme.codeThemeKey)|\(isComplete)|\(language ?? "")|\(code.count)"
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        didCopy = true
    }
}

#Preview("Complete") {
    CodeBlockView(language: "swift", code: "let x = 1\nprint(x)", isComplete: true)
        .padding()
        .frame(width: 360)
}

#Preview("Streaming") {
    CodeBlockView(language: "python", code: "def main():\n    return", isComplete: false)
        .padding()
        .frame(width: 360)
}
