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

            HorizontalCodeScrollView(
                text: highlighted ?? settledCacheProbe ?? plainMemo.attributed(for: code),
                foreground: theme.codeForeground
            )
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

#if canImport(AppKit)
/// A horizontal-only code scroller that hands vertical trackpad gestures to
/// the transcript. SwiftUI's horizontal `ScrollView` consumes both axes on
/// macOS, so merely moving the pointer over a code block could stop the outer
/// conversation mid-scroll.
private struct HorizontalCodeScrollView: NSViewRepresentable {
    let text: AttributedString
    let foreground: Color

    func makeNSView(context: Context) -> CodeScrollView {
        let scrollView = CodeScrollView()
        scrollView.setContent(text, foreground: foreground)
        return scrollView
    }

    func updateNSView(_ scrollView: CodeScrollView, context: Context) {
        scrollView.setContent(text, foreground: foreground)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView scrollView: CodeScrollView, context: Context
    ) -> CGSize? {
        let contentSize = scrollView.contentFittingSize
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? contentSize.width
        return CGSize(width: width, height: contentSize.height)
    }
}

@MainActor
private final class CodeScrollView: NSScrollView {
    private enum GestureAxis {
        case horizontal
        case vertical
    }

    private let codeTextView: TranscriptSelectableTextView
    private var gestureAxis: GestureAxis?
    private var renderedText: AttributedString?
    private var renderedForeground: Color?
    private(set) var contentFittingSize = CGSize(width: 1, height: 1)

    override init(frame frameRect: NSRect) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        codeTextView = TranscriptSelectableTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        usesPredominantAxisScrolling = true

        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isRichText = true
        codeTextView.drawsBackground = false
        codeTextView.textContainerInset = NSSize(width: 10, height: 10)
        codeTextView.isHorizontallyResizable = true
        codeTextView.isVerticallyResizable = true
        codeTextView.minSize = .zero
        codeTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        codeTextView.focusRingType = .none
        documentView = codeTextView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ text: AttributedString, foreground: Color) {
        guard renderedText != text || renderedForeground != foreground else { return }
        renderedText = text
        renderedForeground = foreground

        codeTextView.textStorage?.setAttributedString(
            Self.nativeText(text, foreground: foreground)
        )
        guard let layoutManager = codeTextView.layoutManager,
            let textContainer = codeTextView.textContainer
        else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let size = CGSize(
            width: max(1, ceil(used.width) + 20),
            height: max(1, ceil(used.height) + 20)
        )
        contentFittingSize = size
        if codeTextView.frame.size != size {
            codeTextView.setFrameSize(size)
            reflectScrolledClipView(contentView)
        }
    }

    private static func nativeText(
        _ text: AttributedString, foreground: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(foreground),
            ]
            if let tokenColor = run.foregroundColor {
                attributes[.foregroundColor] = NSColor(tokenColor)
            }
            result.append(
                NSAttributedString(
                    string: String(text[run.range].characters),
                    attributes: attributes
                )
            )
        }
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || gestureAxis == nil || !hasGesturePhase {
            gestureAxis = preferredAxis(for: event)
        }

        if gestureAxis == .vertical, let outerScrollView = enclosingVerticalScrollView {
            outerScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }

        if !hasGesturePhase || event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
        {
            gestureAxis = nil
        }
    }

    private func preferredAxis(for event: NSEvent) -> GestureAxis {
        if event.modifierFlags.contains(.shift) { return .horizontal }
        return abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? .vertical : .horizontal
    }

    private var enclosingVerticalScrollView: NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView, scrollView !== self,
                scrollView.hasVerticalScroller
            {
                return scrollView
            }
            ancestor = view.superview
        }
        return nil
    }
}
#endif

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
