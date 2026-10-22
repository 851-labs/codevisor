#if canImport(AppKit)
  import AppKit
  import SwiftUI

  struct SettledMarkdownRepresentable: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let streamID: String
    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.markdownImageLoader) private var imageLoader
    @Environment(\.streamMarkdownTextLayoutWidth) private var layoutWidth
    @Environment(\.markdownTableBleedLimit) private var tableBleedLimit

    static func canRender(_ blocks: [MarkdownBlock]) -> Bool {
      !blocks.isEmpty
        && blocks.allSatisfy { block in
          guard case let .list(list) = block else { return true }
          return MarkdownTextRunRenderer.canRenderFlattenedList(list)
        }
    }

    func makeNSView(context: Context) -> SettledMarkdownView {
      let view = SettledMarkdownView(frame: .zero)
      view.onContentHeightChange = { [weak view] in view?.invalidateIntrinsicContentSize() }
      return view
    }

    func updateNSView(_ view: SettledMarkdownView, context _: Context) {
      view.tableBleedLimit = tableBleedLimit
      view.setContent(
        blocks: blocks, theme: theme, streamID: streamID, linkAction: linkAction, imageLoader: imageLoader)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SettledMarkdownView, context _: Context) -> CGSize? {
      let proposed = proposal.width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
      guard let width = proposed ?? layoutWidth else { return nil }
      return CGSize(width: width, height: view.contentHeight(forWidth: width))
    }
  }
#endif
