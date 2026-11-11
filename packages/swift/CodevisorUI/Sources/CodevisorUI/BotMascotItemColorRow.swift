import CodevisorCore
import SwiftUI

struct BotMascotItemColorRow: View {
  private static let autoTitle = "Auto"
  private static let autoBadge = "wand.and.sparkles"
  private static let autoFallback = "#9198A6"

  let item: ServerBotMascotOptions.Choice
  let accent: String?
  let side: CGFloat
  @Binding var selection: String

  var body: some View {
    BotMascotSwatchRows(spacing: side / 4) {
      if item.hasAuto { autoSwatch }
      ForEach(item.swatches) { swatch in
        BotMascotColorSwatch(title: swatch.title, hexes: [swatch.hex], side: side, isSelected: shown == swatch.id) {
          selection = swatch.id
        }
      }
    }
  }

  private var autoSwatch: some View {
    BotMascotColorSwatch(
      title: Self.autoTitle,
      hexes: [accent ?? Self.autoFallback],
      side: side,
      isSelected: shown == ServerBotMascot.autoColor,
      badge: Self.autoBadge
    ) {
      selection = ServerBotMascot.autoColor
    }
  }

  private var shown: String {
    item.shownSwatch(for: selection)
  }
}
