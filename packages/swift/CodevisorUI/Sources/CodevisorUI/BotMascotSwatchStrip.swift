import SwiftUI

struct BotMascotSwatchStrip<Swatches: View>: View {
  let spacing: CGFloat
  @ViewBuilder let swatches: () -> Swatches

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row
      ScrollView(.horizontal, showsIndicators: false) { row }
    }
  }

  private var row: some View {
    HStack(spacing: spacing) { swatches() }
  }
}
