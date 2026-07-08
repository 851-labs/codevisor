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
    @State private var copyResetTask: Task<Void, Never>?
    @State private var highlighted: AttributedString?
    /// Memoizes the plain-text fallback: `AttributedString(code)` in `body`
    /// re-allocated attributed storage for the entire block on every body
    /// evaluation — for a streaming block, every ~16ms flush.
    @State private var plainMemo = PlainCodeMemo()

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
                    Label {
                        Text(didCopy ? "Copied" : "Copy")
                    } icon: {
                        // Fixed box: the two glyphs have different intrinsic
                        // heights, which would otherwise resize the header.
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .frame(width: 13, height: 13)
                    }
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
                // The shared-cache probe makes a recycled block (scrolled out
                // and back in a LazyVStack, which resets `highlighted`) render
                // colored on its first frame — no plain flash, no relayout
                // when the async highlighter would otherwise swap in.
                Text(highlighted ?? settledCacheProbe ?? plainMemo.attributed(for: code))
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
            // Already rendered synchronously from the shared cache.
            if settledCacheProbe != nil { return }
            // Mid-stream, wait out further chunks before re-tokenizing; the
            // task(id:) cancellation makes this a trailing-edge debounce.
            if !isComplete {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            if let result = await highlighter(code, language), !Task.isCancelled {
                // Only settled blocks enter the shared cache: mid-stream
                // texts change every flush and would churn the LRU.
                if isComplete {
                    CodeHighlightResultCache.shared.store(result, for: resultCacheKey)
                }
                highlighted = result
            }
        }
    }

    private var resultCacheKey: CodeHighlightResultCache.Key {
        CodeHighlightResultCache.Key(themeKey: theme.codeThemeKey, language: language, code: code)
    }

    /// The shared-cache lookup, gated on `isComplete`: only settled blocks are
    /// ever stored, so a mid-stream probe is a guaranteed miss that still
    /// hashes the whole growing code string — on every body evaluation.
    private var settledCacheProbe: AttributedString? {
        isComplete ? CodeHighlightResultCache.shared.value(for: resultCacheKey) : nil
    }

    // Re-highlight when the content grows, the block completes, or the theme
    // changes (via codeThemeKey — the highlighter closure itself can't be
    // compared). utf8.count: grapheme counting is O(n) per body evaluation.
    private var highlightTaskKey: String {
        "\(theme.codeThemeKey)|\(isComplete)|\(language ?? "")|\(code.utf8.count)"
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        didCopy = true
        // Flash the confirmation, then settle back to "Copy" (matching the
        // transcript's MessageCopyButton). Re-copying restarts the timer.
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

/// Last-value memo for the un-highlighted fallback text. Plain class in
/// `@State`: non-observable, and the `code` comparison is O(1) between
/// flushes (same String storage) — it does real work only when the block
/// actually grows.
@MainActor
private final class PlainCodeMemo {
    private var code: String?
    private var cached: AttributedString?

    func attributed(for code: String) -> AttributedString {
        if let cached, code == self.code { return cached }
        let attributed = AttributedString(code)
        self.code = code
        cached = attributed
        return attributed
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
