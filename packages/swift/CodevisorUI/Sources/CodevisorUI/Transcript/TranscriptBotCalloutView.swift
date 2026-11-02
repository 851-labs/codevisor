import StreamMarkdown
import SwiftUI
import TranscriptKit

public struct TranscriptBotCalloutView: View {
  private let callout: TranscriptBotCallout
  private let streamID: String
  @Environment(\.markdownTheme) private var theme

  public init(callout: TranscriptBotCallout, streamID: String) {
    self.callout = callout
    self.streamID = streamID
  }

  public var body: some View {
    HStack(alignment: .top, spacing: MarkdownFragmentMetrics.quoteIndent - MarkdownFragmentMetrics.quoteBarWidth) {
      Rectangle()
        .fill(theme.quoteBarColor)
        .frame(width: MarkdownFragmentMetrics.quoteBarWidth)
      VStack(alignment: .leading, spacing: 2) {
        Text(callout.label)
          .font(.caption.bold())
        MarkdownBlockGroupsView(blocks: callout.blocks, documentSource: callout.markdown, streamID: streamID)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
