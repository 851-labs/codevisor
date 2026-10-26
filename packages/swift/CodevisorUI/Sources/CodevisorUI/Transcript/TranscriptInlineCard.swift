import SwiftUI

public struct TranscriptInlineCard: View {
  public enum State {
    case pending(message: String, actions: [Action])
    case resolved(Outcome)
  }

  public enum Tone: Sendable {
    case neutral
    case error
  }

  public enum Outcome: Equatable, Sendable {
    case completed(String)
    case declined(String)
  }

  private let title: String
  private let state: State
  private let inBotConversation: Bool
  private let tone: Tone

  public init(title: String, state: State, inBotConversation: Bool, tone: Tone = .neutral) {
    self.title = title
    self.state = state
    self.inBotConversation = inBotConversation
    self.tone = tone
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
        TranscriptInlineCardText(title: title, message: message, tone: tone)
        if !actions.isEmpty {
          TranscriptInlineCardActions(actions: actions)
            .minimumScaleFactor(TranscriptInlineCardMetrics.actionLabelMinimumScale)
        }
      }
    case let .resolved(outcome):
      TranscriptInlineCardResolvedRow(title: title, outcome: outcome)
    }
  }

  private var verticalPadding: CGFloat {
    switch state {
    case .pending: ComposerCardStyle.contentPadding
    case .resolved: TranscriptInlineCardMetrics.resolvedVerticalPadding
    }
  }
}
