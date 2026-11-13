import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

struct ThreadAuthorAvatar: View {
  let author: TranscriptBotAuthor
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?

  var body: some View {
    if let bot {
      BotAvatar(bot: bot, size: TranscriptAuthorAvatarMetrics.size)
        .accessibilityLabel(author.name)
    } else {
      Image(systemName: "bubble.and.pencil")
        .font(.system(size: TranscriptAuthorAvatarMetrics.size * 0.42))
        .foregroundStyle(.secondary)
        .frame(width: TranscriptAuthorAvatarMetrics.size, height: TranscriptAuthorAvatarMetrics.size)
        .background(Color.primary.opacity(0.08), in: Circle())
        .accessibilityLabel(author.name)
    }
  }

  private var bot: Bot? {
    let id = author.id.lowercased()
    return environment?.bots.bots.first { $0.record.id.lowercased() == id }
  }
}
