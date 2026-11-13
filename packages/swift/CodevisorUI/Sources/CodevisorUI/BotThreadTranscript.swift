import CodevisorCore
import SwiftUI

public struct BotThreadTranscript<Avatar: View>: View {
  private let rows: [ThreadBubble]
  private let hasOlder: Bool
  private let loadOlder: () -> Void
  private let avatar: (ServerThreadParticipant) -> Avatar

  public init(
    messages: [ServerThreadMessage],
    hasOlder: Bool,
    loadOlder: @escaping () -> Void,
    @ViewBuilder avatar: @escaping (ServerThreadParticipant) -> Avatar
  ) {
    rows = ThreadBubble.rows(for: messages)
    self.hasOlder = hasOlder
    self.loadOlder = loadOlder
    self.avatar = avatar
  }

  public var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if hasOlder {
          Button("Load Earlier Messages", action: loadOlder)
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        ForEach(rows) { row in
          BotThreadBubbleRow(row: row, avatar: avatar)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: BotThreadMetrics.maxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.bottom)
  }
}

enum BotThreadMetrics {
  static let maxWidth: CGFloat = 760
  static let avatarSize: CGFloat = 28
  static let bubbleCornerRadius: CGFloat = 18
}

private struct BotThreadBubbleRow<Avatar: View>: View {
  let row: ThreadBubble
  let avatar: (ServerThreadParticipant) -> Avatar

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if row.showsName {
        Text(displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, BotThreadMetrics.avatarSize + 20)
          .padding(.top, 10)
      }
      HStack(alignment: .bottom, spacing: 8) {
        Color.clear
          .frame(width: BotThreadMetrics.avatarSize, height: BotThreadMetrics.avatarSize)
          .overlay {
            if row.showsAvatar { avatar(row.message.from) }
          }
        Text(Self.formatted(row.message.text))
          .textSelection(.enabled)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background(
            .quaternary, in: RoundedRectangle(cornerRadius: BotThreadMetrics.bubbleCornerRadius, style: .continuous)
          )
          .frame(maxWidth: 520, alignment: .leading)
        Spacer(minLength: 40)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(displayName): \(row.message.text)")
  }

  private var displayName: String {
    row.message.from.name.isEmpty ? "Agent" : row.message.from.name
  }

  private static func formatted(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }
}
