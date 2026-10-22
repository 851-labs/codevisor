import SwiftUI

struct FirstLaunchMeasurement: ViewModifier {
  let isFrozen: Bool
  let report: (CGRect) -> Void

  func body(content: Content) -> some View {
    content.onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: { frame in
      guard !isFrozen else { return }
      report(frame)
    }
  }
}
