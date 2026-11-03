import ACPKit
import CodevisorCore
import SwiftUI

public struct TranscriptBotTypingRow: View {
  private static let mascotSlot: CGFloat = 26

  let controller: SessionController
  let afterReply: Bool

  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

  public init(controller: SessionController, afterReply: Bool) {
    self.controller = controller
    self.afterReply = afterReply
  }

  public var body: some View {
    Group {
      if let bot, let mascot = bot.mascot {
        mascotIndicator(mascot, serverId: bot.serverId)
      } else {
        HStack {
          BotTypingBubble()
          Spacer(minLength: 0)
        }
      }
    }
    .suppressedDuringStreamingTextEntrance()
  }

  @ViewBuilder
  private func mascotIndicator(_ mascot: ServerBotMascot, serverId: String) -> some View {
    let status = BotTypingStatus(turn: activeTurn)
    let isShown = status.isShown(afterReply: afterReply)
    Group {
      if isShown {
        HStack(spacing: 8) {
          BotMascotFigure(
            mascot: mascot, serverId: serverId, slot: Self.mascotSlot, motion: status.motion)
          ShimmeringText(text: status.text)
          Spacer(minLength: 0)
        }
        .frame(height: UserBubbleBackground.cornerRadius(for: dynamicTypeSize) * 2)
        .accessibilityElement(children: .combine)
      } else {
        Color.clear.frame(height: 0)
      }
    }
    .onChange(of: isShown, initial: true) { _, shown in
      BotReplyHandoff.shared.note(shown: shown, for: controller)
      invalidateRowMeasurement?()
    }
    .onDisappear { BotReplyHandoff.shared.note(shown: false, for: controller) }
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
