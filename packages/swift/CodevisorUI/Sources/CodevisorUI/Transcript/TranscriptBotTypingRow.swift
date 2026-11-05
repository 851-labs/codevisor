import ACPKit
import CodevisorCore
import SwiftUI

public struct TranscriptBotTypingRow: View {
  let controller: SessionController

  @Environment(AppEnvironment.self) private var environment: AppEnvironment?

  public init(controller: SessionController) {
    self.controller = controller
  }

  public var body: some View {
    Group {
      if let bot, let mascot = bot.mascot {
        BotTypingMascotIndicator(bot: bot, mascot: mascot, activity: BotTypingStatus.activity(of: activeTurn))
      } else {
        HStack {
          BotTypingBubble()
          Spacer(minLength: 0)
        }
      }
    }
    .suppressedDuringStreamingTextEntrance()
  }

  private var bot: Bot? {
    guard let session = controller.serverSession else { return nil }
    return environment?.bots.bot(forSession: session.id, serverId: session.serverId)
  }

  private var activeTurn: AssistantTurn? {
    let _ = controller.activeItemRevision
    guard case let .assistant(message)? = controller.activeItem else { return nil }
    return message.turn
  }
}
