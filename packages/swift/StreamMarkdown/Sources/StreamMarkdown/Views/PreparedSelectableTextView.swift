#if canImport(AppKit) || canImport(UIKit)
  import MarkdownCore
  import SwiftUI

  struct PreparedSelectableTextView: View {
    private let content: PreparedTextContent
    var wrapsText = true
    @Environment(\.streamMarkdownTextLayoutWidth) private var rowWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredWidth: CGFloat = 320
    @State private var prepared: PreparedNativeTextLayout?
    @State private var preparedRequest: Request?
    @State private var worker = LatestValuePreparationWorker<Request, PreparedNativeTextLayout> { request in
      #if canImport(UIKit) && !canImport(AppKit)
        try request.traits.perform {
          try request.prepare()
        }
      #else
        try request.prepare()
      #endif
    }

    private struct Request: Hashable, @unchecked Sendable {
      let content: PreparedTextContent
      let width: CGFloat
      let wrapsText: Bool
      let dynamicTypeSize: DynamicTypeSize
      let colorScheme: ColorScheme
      #if canImport(UIKit) && !canImport(AppKit)
        let traits: MarkdownRenderingTraits
      #endif

      @MainActor init(
        content: PreparedTextContent, width: CGFloat, wrapsText: Bool,
        dynamicTypeSize: DynamicTypeSize, colorScheme: ColorScheme
      ) {
        self.content = content
        self.width = width
        self.wrapsText = wrapsText
        self.dynamicTypeSize = dynamicTypeSize
        self.colorScheme = colorScheme
        #if canImport(UIKit) && !canImport(AppKit)
          traits = MarkdownRenderingTraits(dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme)
        #endif
      }

      static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width && lhs.wrapsText == rhs.wrapsText && lhs.dynamicTypeSize == rhs.dynamicTypeSize
          && lhs.colorScheme == rhs.colorScheme && lhs.content.key == rhs.content.key
      }

      func hash(into hasher: inout Hasher) {
        hasher.combine(content.key)
        hasher.combine(width)
        hasher.combine(wrapsText)
        hasher.combine(dynamicTypeSize)
        hasher.combine(colorScheme)
      }

      func prepare() throws -> PreparedNativeTextLayout {
        try content.prepare(width: width, wrapsText: wrapsText)
      }
    }

    init(text: NSAttributedString, wrapsText: Bool = true) {
      content = .attributed(text)
      self.wrapsText = wrapsText
    }

    init(blocks: [MarkdownBlock], theme: MarkdownTheme, foregroundColor: Color) {
      content = .markdown(blocks: blocks, theme: theme, foregroundColor: foregroundColor)
    }

    #if canImport(AppKit)
      init(
        headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]], theme: MarkdownTheme,
        images: [String: MarkdownImageResource] = [:]
      ) {
        content = .table(headers: headers, alignments: alignments, rows: rows, theme: theme, images: images)
      }
    #endif

    private var requestWidth: CGFloat {
      guard wrapsText else { return 1_000_000 }
      return rowWidth.flatMap { $0 > 1 ? $0 : nil } ?? measuredWidth
    }

    var body: some View {
      let request = Request(
        content: content,
        width: requestWidth,
        wrapsText: wrapsText, dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme
      )
      Group {
        if let prepared {
          #if canImport(AppKit)
            if case let .table(_, _, _, theme, _) = content {
              PreparedTableNativeView(layout: prepared, borderColor: theme.tableBorderColor)
            } else if wrapsText {
              PreparedNativeTextView(layout: prepared)
            } else {
              PreparedCodeScrollView(layout: prepared)
            }
          #else
            PreparedNativeTextView(layout: prepared)
          #endif
        } else {
          Color.clear
        }
      }
      .frame(width: contentWidth, height: contentHeight)
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
        if width > 1 { measuredWidth = width }
      }
      .preference(key: ContentLayoutReadinessPreferenceKey.self, value: preparedRequest == request ? 0 : 1)
      .task(id: request) {
        guard preparedRequest != request else { return }
        #if canImport(AppKit)
          if !wrapsText, let prepared, let previous = preparedRequest,
            let previousText = previous.content.attributedText, let text = content.attributedText,
            previousText.string == text.string, text.length > 0,
            let previousFont = previousText.attribute(.font, at: 0, effectiveRange: nil) as? NSObject,
            let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSObject,
            previousFont.isEqual(font)
          {
            prepared.updateForegroundColors(from: text)
            preparedRequest = request
            return
          }
        #endif
        worker.submit(request) { request, result in
          switch result {
          case let .success(layout):
            prepared = layout
            preparedRequest = request
          case .failure(is CancellationError):
            break
          case let .failure(error):
            assertionFailure("Unexpected text preparation failure: \(error)")
          }
        }
      }
      .onDisappear { worker.cancel() }
    }

    private var contentWidth: CGFloat? {
      #if canImport(AppKit)
        nil
      #else
        wrapsText ? nil : prepared?.size.width
      #endif
    }

    private var contentHeight: CGFloat {
      #if canImport(AppKit)
        (prepared?.size.height ?? 320) + (wrapsText ? 0 : 20)
      #else
        prepared?.size.height ?? 320
      #endif
    }
  }

  #if canImport(AppKit)
    private struct PreparedNativeTextView: NSViewRepresentable {
      let layout: PreparedNativeTextLayout
      @Environment(\.markdownLinkAction) private var linkAction

      func makeNSView(context: Context) -> SelectableTextKitView {
        let view = SelectableTextKitView(preparedLayout: layout)
        view.linkAction = linkAction
        return view
      }

      func updateNSView(_ view: SelectableTextKitView, context: Context) {
        view.adoptPreparedLayout(layout)
        view.linkAction = linkAction
      }

      func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextKitView, context: Context) -> CGSize? {
        layout.size
      }
    }
  #else
    private struct PreparedNativeTextView: UIViewRepresentable {
      let layout: PreparedNativeTextLayout
      @Environment(\.markdownLinkAction) private var linkAction
      @Environment(\.textSelectionSession) private var selectionSession

      func makeCoordinator() -> SelectableTextView.Coordinator { .init() }

      func makeUIView(context: Context) -> PreparedTextContainerView {
        let view = PreparedTextContainerView()
        updateUIView(view, context: context)
        return view
      }

      func updateUIView(_ view: PreparedTextContainerView, context: Context) {
        view.configure(layout: layout, delegate: context.coordinator, selectionSession: selectionSession)
        context.coordinator.linkAction = linkAction
      }

      func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreparedTextContainerView, context: Context) -> CGSize? {
        layout.size
      }
    }
  #endif
#endif
