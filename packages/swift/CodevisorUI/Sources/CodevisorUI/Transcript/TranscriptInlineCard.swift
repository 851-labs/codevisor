import SwiftUI

public struct TranscriptInlineCard: View {
  public enum State {
    case pending(message: String, actions: [ComposerNoticeCard.Action])
    case resolved(Outcome)
  }

  public enum Outcome: Equatable, Sendable {
    case completed(String)
    case declined(String)
  }

  private let systemImage: String
  private let title: String
  private let state: State
  private let inBotConversation: Bool

  public init(systemImage: String, title: String, state: State, inBotConversation: Bool) {
    self.systemImage = systemImage
    self.title = title
    self.state = state
    self.inBotConversation = inBotConversation
  }

  public var body: some View {
    HStack(spacing: 0) {
      content
        .padding(.horizontal, ComposerCardStyle.contentPadding)
        .padding(.vertical, verticalPadding)
        .modifier(TranscriptInlineCardSurface(inBotConversation: inBotConversation))
        .frame(maxWidth: TranscriptInlineCardMetrics.maxWidth, alignment: .leading)
      Spacer(minLength: inBotConversation ? TranscriptInlineCardMetrics.bubbleTrailingInset : 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case let .pending(message, actions):
      VStack(alignment: .leading, spacing: TranscriptInlineCardMetrics.actionSpacing) {
        NoticeCardText(title: title, detail: message, systemImage: systemImage, accent: .accentColor)
        NoticeCardActions(actions: actions, fillsWidth: true, controlSize: TranscriptInlineCardMetrics.controlSize)
      }
    case let .resolved(outcome):
      TranscriptInlineCardResolvedRow(systemImage: systemImage, title: title, outcome: outcome)
    }
  }

  private var verticalPadding: CGFloat {
    switch state {
    case .pending: ComposerCardStyle.contentPadding
    case .resolved: TranscriptInlineCardMetrics.resolvedVerticalPadding
    }
  }
}
