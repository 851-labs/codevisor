import SwiftUI

public struct MarkdownFragmentsView: View {
  private let fragments: [MarkdownFragment]
  private let documentSource: String
  private let streamID: String
  @Environment(\.markdownBlockChrome) private var chrome

  public init(fragments: [MarkdownFragment], documentSource: String, streamID: String) {
    self.fragments = fragments
    self.documentSource = documentSource
    self.streamID = streamID
  }

  public var body: some View {
    #if canImport(AppKit)
      if chrome.drawsFrame {
        SettledMarkdownRepresentable(fragments: fragments, streamID: streamID)
      } else {
        fragmentStack
      }
    #else
      fragmentStack
    #endif
  }

  private var fragmentStack: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(fragments.indices, id: \.self) { index in
        MarkdownFragmentStackItem(
          fragment: fragments[index], documentSource: documentSource, streamID: "\(streamID).\(index)")
      }
    }
  }
}

private struct MarkdownFragmentStackItem: View {
  let fragment: MarkdownFragment
  let documentSource: String
  let streamID: String
  @Environment(\.markdownTheme) private var theme

  var body: some View {
    content.padding(.top, theme.gap(above: fragment))
  }

  @ViewBuilder private var content: some View {
    if let layout = fragment.layout {
      MarkdownFragmentRenderView(
        blocks: fragment.blocks, documentSource: documentSource, streamID: streamID, isStreaming: false,
        layout: layout)
    } else {
      MarkdownBlockRenderView(
        blocks: fragment.blocks, documentSource: documentSource, streamID: streamID, isStreaming: false)
    }
  }
}
