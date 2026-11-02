import CodevisorCore
import SwiftUI

struct BotMascotItemTile: View {
  private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
  private static let inset: CGFloat = 6
  private static let selectionWidth: CGFloat = 2.5

  let title: String
  let mascot: ServerBotMascot
  let serverId: String
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      BotMascotImage(mascot: mascot, serverId: serverId)
        .padding(Self.inset)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay {
          if isSelected {
            Self.shape.strokeBorder(.secondary, lineWidth: Self.selectionWidth)
          }
        }
        .contentShape(Self.shape)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
