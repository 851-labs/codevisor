import CodevisorCore
import SwiftUI

public struct BotMascotCategoryControls: View {
  let category: BotMascotCategory
  let options: ServerBotMascotOptions
  let serverId: String
  let columns: [GridItem]
  let swatchSide: CGFloat
  @Binding var mascot: ServerBotMascot

  public init(
    category: BotMascotCategory,
    options: ServerBotMascotOptions,
    serverId: String,
    columns: [GridItem],
    swatchSide: CGFloat,
    mascot: Binding<ServerBotMascot>
  ) {
    self.category = category
    self.options = options
    self.serverId = serverId
    self.columns = columns
    self.swatchSide = swatchSide
    _mascot = mascot
  }

  public var body: some View {
    switch category {
    case .color:
      BotMascotColorRow(colors: options.colors, side: swatchSide, selection: $mascot.color)
    case .headwear:
      itemPicker(.hat)
    case .eyewear:
      itemPicker(.eyewear)
    }
  }

  private func itemPicker(_ part: ServerBotMascotPart) -> some View {
    BotMascotItemPicker(
      part: part, options: options, serverId: serverId, columns: columns, swatchSide: swatchSide, mascot: $mascot
    )
  }
}
