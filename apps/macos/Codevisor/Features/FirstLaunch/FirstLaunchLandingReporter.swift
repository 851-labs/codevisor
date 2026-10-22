import CodevisorUI
import SwiftUI

struct FirstLaunchLandingReporter: ViewModifier {
  let target: FirstLaunchLandingTarget
  private let composerStyle = ComposerCardStyle()

  func body(content: Content) -> some View {
    content
      .overlay {
        if target == .composer, let landing = AppRuntime.shared.firstLaunchLanding {
          FirstLaunchCatchRing(isCaught: landing.hasCaughtCard, cornerRadius: composerStyle.cornerRadius)
        }
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: { frame in
        AppRuntime.shared.firstLaunchLanding?.report(frame, for: target)
      }
  }
}

extension View {
  func firstLaunchLandingTarget(_ target: FirstLaunchLandingTarget) -> some View {
    modifier(FirstLaunchLandingReporter(target: target))
  }
}
