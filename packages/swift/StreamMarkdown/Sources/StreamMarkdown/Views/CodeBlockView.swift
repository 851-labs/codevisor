import MarkdownCore
import SwiftUI
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

public struct CodeBlockView<Title: View, Accessory: View>: View {
  let id: String
  let language: String?
  let code: String
  let isComplete: Bool
  private let maxHeight: CGFloat?
  private let title: Title
  private let accessory: Accessory

  @Environment(\.markdownTheme) private var theme
  @State private var highlighted: CodeHighlightSnapshot?
  @State private var plainMemo = PlainCodeMemo()
  @State private var usesPreparedLayout: Bool
  #if canImport(AppKit) || canImport(UIKit)
    @State private var nativeMemo = NativeCodeMemo()
  #endif

  public init(
    id: String,
    language: String?,
    code: String,
    isComplete: Bool,
    maxHeight: CGFloat? = nil,
    @ViewBuilder title: () -> Title,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.id = id
    self.language = language
    self.code = code
    self.isComplete = isComplete
    self.maxHeight = maxHeight
    self.title = title()
    self.accessory = accessory()
    _usesPreparedLayout = State(
      initialValue: isComplete && code.utf8.count > MarkdownLayoutPolicy.maximumSynchronousTextBytes
    )
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        title
        if !isComplete {
          ProgressView()
            .controlSize(.mini)
        }
        Spacer()
        accessory
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)

      Divider()

      CodeBlockHeightLimit(maxHeight: maxHeight) {
        codeText
      }
    }
    .background(theme.codeBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task(id: highlightTaskKey) {
      guard let highlighter = theme.codeHighlighter else { return }
      if settledCacheProbe != nil { return }
      if !isComplete {
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }
      }
      let request = CodeHighlightRequest(
        id: id,
        code: code,
        language: language,
        isComplete: isComplete
      )
      if let result = await highlighter(request), !Task.isCancelled {
        if isComplete {
          CodeHighlightResultCache.shared.store(result, for: resultCacheKey)
        }
        highlighted = CodeHighlightSnapshot(
          source: code, language: language, themeKey: theme.codeThemeKey, text: result
        )
      }
    }
  }

  @ViewBuilder private var codeText: some View {
    #if canImport(AppKit)
      if usesPreparedLayout {
        PreparedSelectableTextView(
          text: nativeMemo.attributed(for: renderedText, fallback: theme.codeForeground), wrapsText: false
        )
      } else {
        HorizontalCodeScrollView(
          text: renderedText,
          foreground: theme.codeForeground
        )
      }
    #elseif canImport(UIKit)
      ScrollView(.horizontal, showsIndicators: false) {
        if usesPreparedLayout {
          PreparedSelectableTextView(
            text: nativeMemo.attributed(for: renderedText, fallback: theme.codeForeground), wrapsText: false
          ).padding(10)
        } else {
          SelectableTextView(
            attributedText: nativeMemo.attributed(
              for: renderedText,
              fallback: theme.codeForeground
            ),
            fillsWidth: false
          )
          .padding(10)
        }
      }
    #else
      ScrollView(.horizontal, showsIndicators: false) {
        Text(renderedText)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(theme.codeForeground)
          .padding(10)
      }
    #endif
  }

  private var resultCacheKey: CodeHighlightResultCache.Key {
    CodeHighlightResultCache.Key(themeKey: theme.codeThemeKey, language: language, code: code)
  }

  private var renderedText: AttributedString {
    settledCacheProbe
      ?? highlighted?.renderedText(source: code, language: language, themeKey: theme.codeThemeKey)
      ?? plainMemo.attributed(for: code)
  }

  private var settledCacheProbe: AttributedString? {
    isComplete ? CodeHighlightResultCache.shared.value(for: resultCacheKey) : nil
  }

  private struct HighlightTaskKey: Equatable {
    let result: CodeHighlightResultCache.Key
    let isComplete: Bool
  }

  private var highlightTaskKey: HighlightTaskKey {
    HighlightTaskKey(result: resultCacheKey, isComplete: isComplete)
  }

}

extension CodeBlockView where Title == CodeBlockLanguageTitle, Accessory == CodeBlockCopyButton {
  init(id: String, language: String?, code: String, isComplete: Bool) {
    self.init(id: id, language: language, code: code, isComplete: isComplete) {
      CodeBlockLanguageTitle(language: language)
    } accessory: {
      CodeBlockCopyButton(code: code)
    }
  }
}

#if canImport(AppKit) || canImport(UIKit)
  @MainActor
  private final class NativeCodeMemo {
    private var text: AttributedString?
    private var fontSize: CGFloat?
    private var fallback: Color?
    private var cached: NSAttributedString?

    func attributed(for text: AttributedString, fallback: Color) -> NSAttributedString {
      #if canImport(UIKit)
        let font = UIFont.scaledMonospacedSystemFont(forTextStyle: .callout)
      #else
        let font = NSFont.monospacedSystemFont(
          ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
      #endif
      let size = font.pointSize
      if let cached, text == self.text, size == fontSize, fallback == self.fallback {
        return cached
      }
      let result = NSMutableAttributedString()
      let fallbackColor = MarkdownNativeColor(fallback)
      for run in text.runs {
        result.append(
          NSAttributedString(
            string: String(text[run.range].characters),
            attributes: [
              .font: font,
              .foregroundColor: run.foregroundColor.map { MarkdownNativeColor($0) }
                ?? fallbackColor,
            ]
          )
        )
      }
      self.text = text
      fontSize = size
      self.fallback = fallback
      cached = result
      return result
    }
  }
#endif

#if canImport(AppKit)
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
  private final class CodeScrollView: TranscriptHorizontalScrollView {
    private let codeTextView: TranscriptSelectableTextView
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
        nativeCodeAttributedString(text, foreground: NSColor(foreground))
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

  }
#endif

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
  CodeBlockView(id: "preview", language: "swift", code: "let x = 1\nprint(x)", isComplete: true)
    .padding()
    .frame(width: 360)
}

#Preview("Streaming") {
  CodeBlockView(
    id: "preview",
    language: "python",
    code: "def main():\n    return",
    isComplete: false
  )
  .padding()
  .frame(width: 360)
}
