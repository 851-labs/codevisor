import StreamMarkdown
import SwiftUI
import TranscriptKit

public enum TranscriptAuthorAvatarMetrics {
  public static let size: CGFloat = 28
  public static let spacing: CGFloat = 6
  static let inset = size + spacing
}

struct TranscriptAuthoredBubbleRow<Bubble: View>: View {
  let avatar: AnyView?
  @ViewBuilder let bubble: () -> Bubble

  var body: some View {
    HStack(alignment: .bottom, spacing: TranscriptAuthorAvatarMetrics.spacing) {
      Color.clear
        .frame(width: TranscriptAuthorAvatarMetrics.size, height: TranscriptAuthorAvatarMetrics.size)
        .overlay { avatar }
      bubble()
        .transformEnvironment(\.streamMarkdownTextLayoutWidth) { width in
          width = width.map { max(1, $0 - TranscriptAuthorAvatarMetrics.inset) }
        }
    }
  }
}

struct TranscriptBotAuthorNameRow: View {
  let name: String

  var body: some View {
    Text(name)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.leading, TranscriptAuthorAvatarMetrics.inset + TranscriptSendFlightGeometry.bubbleTextInsets.horizontal)
      .padding(.top, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}
