#if canImport(AppKit)
  import AppKit
  import SwiftUI

  struct SettledMarkdownRepresentable: NSViewRepresentable {
    let fragments: [MarkdownFragment]
    let streamID: String
    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.markdownImageLoader) private var imageLoader
    @Environment(\.streamMarkdownTextLayoutWidth) private var layoutWidth
    @Environment(\.markdownTableBleedLimit) private var tableBleedLimit

    func makeNSView(context: Context) -> SettledMarkdownDocumentView {
      let view = SettledMarkdownDocumentView(frame: .zero)
      view.onContentHeightChange = { [weak view] in view?.invalidateIntrinsicContentSize() }
      return view
    }

    func updateNSView(_ view: SettledMarkdownDocumentView, context _: Context) {
      view.tableBleedLimit = tableBleedLimit
      view.setContent(
        fragments: fragments, theme: theme, streamID: streamID, linkAction: linkAction, imageLoader: imageLoader)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView view: SettledMarkdownDocumentView, context _: Context
    ) -> CGSize? {
      let proposed = proposal.width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
      guard let width = proposed ?? layoutWidth else { return nil }
      return CGSize(width: width, height: view.contentHeight(forWidth: width))
    }
  }
#endif
