import CodevisorCore
import SwiftUI

struct BotMascotItemGrid: View {
  private static let spacing: CGFloat = 12

  let items: [ServerBotMascotOptions.Choice]
  let part: ServerBotMascotPart
  let columns: [GridItem]
  @Binding var mascot: ServerBotMascot

  var body: some View {
    LazyVGrid(columns: columns, spacing: Self.spacing) {
      ForEach(items) { item in
        BotMascotItemTile(
          title: item.title,
          mascot: mascot.wearing(item, on: part),
          isSelected: mascot[keyPath: part.item] == item.id
        ) {
          mascot = mascot.wearing(item, on: part)
        }
      }
    }
  }
}
