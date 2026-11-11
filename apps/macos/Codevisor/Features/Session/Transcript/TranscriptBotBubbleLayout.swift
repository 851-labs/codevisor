import Foundation
import CodevisorUI
import StreamMarkdown
import TranscriptKit

struct TranscriptBotBubbleLayout: Equatable {
  let horizontalInset: CGFloat
  let verticalInset: CGFloat
  let chrome: MarkdownBlockChrome

  static let plainText = text(chrome: .standard)

  static func forPart(_ style: TranscriptBotPartStyle) -> TranscriptBotBubbleLayout? {
    switch style {
    case .text: plainText
    case .quote: text(chrome: .bubble)
    case .code, .table: TranscriptBotBubbleLayout(horizontalInset: 0, verticalInset: 0, chrome: .bubble)
    case .callout, .image: nil
    }
  }

  private static func text(chrome: MarkdownBlockChrome) -> TranscriptBotBubbleLayout {
    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    return TranscriptBotBubbleLayout(
      horizontalInset: insets.horizontal, verticalInset: insets.vertical, chrome: chrome)
  }
}
