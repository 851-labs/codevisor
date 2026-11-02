import CodevisorCore
import CodevisorTheming
import SwiftUI

struct BotMascotColorSwatch: View {
  private static let side: CGFloat = 20
  private static let dotSide: CGFloat = 7

  let color: ServerBotMascotOptions.ColorChoice
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Circle()
        .fill(fill)
        .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
        .overlay {
          if isSelected {
            Circle().fill(.white).frame(width: Self.dotSide, height: Self.dotSide)
          }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .help(color.title)
    .accessibilityLabel(color.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var fill: LinearGradient {
    LinearGradient(
      colors: color.gradient.compactMap(RGBA.init(hex:)).map(Color.init(rgba:)),
      startPoint: .top,
      endPoint: .bottom
    )
  }
}
