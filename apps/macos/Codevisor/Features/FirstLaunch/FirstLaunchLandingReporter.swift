import SwiftUI

struct FirstLaunchLandingReporter: ViewModifier {
  func body(content: Content) -> some View {
    content.onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: { frame in
      AppRuntime.shared.firstLaunchLanding?.reportComposer(frame)
    }
  }
}

extension View {
  func reportsFirstLaunchComposerFrame() -> some View {
    modifier(FirstLaunchLandingReporter())
  }
}
