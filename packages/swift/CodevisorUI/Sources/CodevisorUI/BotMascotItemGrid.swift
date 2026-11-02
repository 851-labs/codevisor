import CodevisorCore
import SwiftUI

struct BotMascotItemGrid: View {
  private static let spacing: CGFloat = 12

  let items: [ServerBotMascotOptions.Choice]
  let part: WritableKeyPath<ServerBotMascot, String>
  let columns: [GridItem]
  @Binding var mascot: ServerBotMascot
  let serverId: String

  var body: some View {
    LazyVGrid(columns: columns, spacing: Self.spacing) {
      ForEach(items) { item in
        BotMascotItemTile(
          title: item.title,
          mascot: wearing(item),
          serverId: serverId,
          isSelected: mascot[keyPath: part] == item.id
        ) {
          mascot[keyPath: part] = item.id
        }
      }
    }
  }

  private func wearing(_ item: ServerBotMascotOptions.Choice) -> ServerBotMascot {
    var tile = mascot
    tile[keyPath: part] = item.id
    return tile
  }
}
