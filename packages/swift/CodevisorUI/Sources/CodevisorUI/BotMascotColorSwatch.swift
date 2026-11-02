import CodevisorCore
import CodevisorTheming
import SwiftUI

struct BotMascotColorSwatch: View {
  private static let ringWidth: CGFloat = 2.5

  let color: ServerBotMascotOptions.ColorChoice
  let side: CGFloat
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Circle()
        .fill(fill)
        .padding(ringGap)
        .overlay {
          if isSelected {
            Circle().strokeBorder(.secondary, lineWidth: Self.ringWidth)
          }
        }
        .frame(width: side + ringGap * 2, height: side + ringGap * 2)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .help(color.title)
    .accessibilityLabel(color.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var ringGap: CGFloat {
    side / 5
  }

  private var fill: LinearGradient {
    LinearGradient(
      colors: color.gradient.compactMap(RGBA.init(hex:)).map(Color.init(rgba:)),
      startPoint: .top,
      endPoint: .bottom
    )
  }
}
