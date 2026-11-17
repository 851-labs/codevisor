import SwiftUI

public struct BotsEmptyState: View {
  private static let messageWidth: CGFloat = 360

  let onNewBot: () -> Void

  public init(onNewBot: @escaping () -> Void) {
    self.onNewBot = onNewBot
  }

  public var body: some View {
    VStack(spacing: 0) {
      BotsEmptyCrew()
      Text("No Bots Yet")
        .font(.title2.weight(.bold))
        .padding(.top, 18)
      Text("Bots are assistants that stick around. Give each one a name and a look, then message it any time.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: Self.messageWidth)
        .padding(.top, 8)
      BotsEmptyNewBotButton(action: onNewBot)
        .padding(.top, 24)
    }
    .multilineTextAlignment(.center)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
