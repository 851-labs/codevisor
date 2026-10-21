import SwiftUI

enum SidebarDragLift: String {
  case material
  case regularGlass
  case clearGlass
  case tintedGlass

  static let defaultsKey = "sidebarDragLift"
  static let preferred = SidebarDragLift.regularGlass

  static var current: SidebarDragLift {
    UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? preferred
  }

  var glass: Glass? {
    switch self {
    case .material: nil
    case .regularGlass: .regular
    case .clearGlass: .clear
    case .tintedGlass: .regular.tint(.accentColor.opacity(0.18))
    }
  }
}

struct SidebarDragLiftModifier: ViewModifier {
  let lift: SidebarDragLift

  func body(content: Content) -> some View {
    if let glass = lift.glass {
      content
        .glassEffect(glass, in: RoundedRectangle.sidebarRow)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    } else {
      content
        .background {
          RoundedRectangle.sidebarRow
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .opacity(0.92)
    }
  }
}

extension View {
  func sidebarDragLift(_ lift: SidebarDragLift = .current) -> some View {
    modifier(SidebarDragLiftModifier(lift: lift))
  }
}
