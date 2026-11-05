import CodevisorCore
import SwiftUI

struct BotTypingMascotIndicator: View {
  private static let mascotSlot: CGFloat = 26

  let bot: Bot
  let mascot: ServerBotMascot
  let activity: WorkedSectionActivity

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var smoother = WorkedActivityLabelSmoother()

  var body: some View {
    let status = BotTypingStatus(activity: smoother.shown ?? WorkedActivityLabelSmoother.initial(activity))
    HStack(spacing: 8) {
      BotMascotFigure(bot: bot, mascot: mascot, slot: Self.mascotSlot)
      ShimmeringText(text: status.text)
      Spacer(minLength: 0)
    }
    .frame(height: UserBubbleBackground.cornerRadius(for: dynamicTypeSize) * 2)
    .accessibilityElement(children: .combine)
    .modifier(WorkedActivitySmoothing(activity: activity, smoother: $smoother))
  }
}
