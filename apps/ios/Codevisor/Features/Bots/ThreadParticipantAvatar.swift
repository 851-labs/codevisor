import CodevisorCore
import SwiftUI

struct ThreadParticipantAvatar: View {
  let participant: ServerThreadParticipant
  let size: CGFloat
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    if let bot {
      BotAvatar(bot: bot, size: size)
    } else {
      Image(systemName: "bubble.and.pencil")
        .font(.system(size: size * 0.42))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.08), in: Circle())
    }
  }

  private var bot: Bot? {
    guard let id = participant.botId.flatMap(UUID.init(uuidString:)) else { return nil }
    return environment.bots.bots.first { $0.id == id }
  }
}

extension ServerThreadParticipant {
  var threadDisplayName: String {
    name.isEmpty ? "Agent" : name
  }
}
