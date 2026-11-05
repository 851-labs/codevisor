import CodevisorCore
import SwiftUI

struct BotMascotItemPicker: View {
  private static let spacing: CGFloat = 16

  let part: ServerBotMascotPart
  let options: ServerBotMascotOptions
  let serverId: String
  let columns: [GridItem]
  let swatchSide: CGFloat
  @Binding var mascot: ServerBotMascot

  var body: some View {
    VStack(alignment: .leading, spacing: Self.spacing) {
      if let colorable {
        BotMascotItemColorRow(
          item: colorable,
          accent: options.accent(for: mascot.color),
          side: swatchSide,
          selection: $mascot[dynamicMember: part.color]
        )
      }
      BotMascotItemGrid(
        items: options.items(for: part), part: part, columns: columns, mascot: $mascot, serverId: serverId
      )
    }
  }

  private var colorable: ServerBotMascotOptions.Choice? {
    let worn = options.items(for: part).first { $0.id == mascot[keyPath: part.item] }
    guard let worn, !worn.swatches.isEmpty else { return nil }
    return worn
  }
}
