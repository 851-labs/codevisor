import CodevisorCore
import SwiftUI

struct BotMascotColorRow: View {
  let colors: [ServerBotMascotOptions.ColorChoice]
  let side: CGFloat
  @Binding var selection: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      swatches
      ScrollView(.horizontal, showsIndicators: false) { swatches }
    }
  }

  private var swatches: some View {
    HStack(spacing: side / 4) {
      ForEach(colors) { color in
        BotMascotColorSwatch(color: color, side: side, isSelected: color.id == selection) {
          selection = color.id
        }
      }
    }
  }
}
