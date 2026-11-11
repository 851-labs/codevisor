import CodevisorCore
import SwiftUI

struct BotMascotColorRow: View {
  let colors: [ServerBotMascotOptions.ColorChoice]
  let side: CGFloat
  @Binding var selection: String

  var body: some View {
    BotMascotSwatchRows(spacing: side / 4) {
      ForEach(colors) { color in
        BotMascotColorSwatch(title: color.title, hexes: color.gradient, side: side, isSelected: color.id == selection) {
          selection = color.id
        }
      }
    }
  }
}
