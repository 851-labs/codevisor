import StreamMarkdown
import SwiftUI
import TranscriptKit

public enum TranscriptAuthorAvatarMetrics {
  public static let size: CGFloat = 28
  public static let spacing: CGFloat = 6
}

struct TranscriptAuthoredBubbleRow<Bubble: View>: View {
  let side: TranscriptBotMessage.Side
  let avatar: AnyView?
  @ViewBuilder let bubble: () -> Bubble

  var body: some View {
    HStack(alignment: .bottom, spacing: TranscriptAuthorAvatarMetrics.spacing) {
      if side == .leading { avatarSlot }
      bubble()
        .transformEnvironment(\.streamMarkdownTextLayoutWidth) { width in
          width = width.map { max(1, $0 - Self.inset) }
        }
      if side == .trailing { avatarSlot }
    }
  }

  private static var inset: CGFloat {
    TranscriptAuthorAvatarMetrics.size + TranscriptAuthorAvatarMetrics.spacing
  }

  private var avatarSlot: some View {
    Color.clear
      .frame(width: TranscriptAuthorAvatarMetrics.size, height: TranscriptAuthorAvatarMetrics.size)
      .overlay { avatar }
  }
}
