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

struct ThreadGroupAvatar: View {
  let bot: Bot
  let participant: ServerThreadParticipant?
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(.ultraThinMaterial)
      BotAvatar(bot: bot, size: size * 0.56)
        .padding([.top, .leading], size * 0.11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      if let participant {
        ThreadParticipantAvatar(participant: participant, size: size * 0.38)
          .padding([.bottom, .trailing], size * 0.1)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

extension ServerThreadParticipant {
  var threadDisplayName: String {
    name.isEmpty ? "Agent" : name
  }
}
