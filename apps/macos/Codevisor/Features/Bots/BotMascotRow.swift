import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotMascotRow: View {
  private static let avatarSize: CGFloat = 32

  let mascot: ServerBotMascot
  let serverId: String
  let edit: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text("Mascot")
      Spacer()
      Button(action: edit) {
        BotMascotAvatar(mascot: mascot, serverId: serverId, size: Self.avatarSize)
      }
      .buttonStyle(.plain)
      .help("Edit Mascot")
      .accessibilityHidden(true)
      Button("Edit Mascot", action: edit)
    }
  }
}
