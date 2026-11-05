import CodevisorCore
import CodevisorTheming
import SwiftUI

struct BotMascotColorSwatch: View {
  private static let ringWidth: CGFloat = 2.5

  let title: String
  let hexes: [String]
  let side: CGFloat
  let isSelected: Bool
  var badge: String?
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Circle()
        .fill(fill)
        .overlay { badgeImage }
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
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder private var badgeImage: some View {
    if let badge {
      Image(systemName: badge)
        .font(.system(size: side * 0.45, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(radius: 1)
    }
  }

  private var ringGap: CGFloat {
    side / 5
  }

  private var fill: LinearGradient {
    LinearGradient(
      colors: hexes.compactMap(RGBA.init(hex:)).map(Color.init(rgba:)),
      startPoint: .top,
      endPoint: .bottom
    )
  }
}
