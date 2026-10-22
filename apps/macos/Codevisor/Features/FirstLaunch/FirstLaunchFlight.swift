import SwiftUI

struct FirstLaunchFlight: ViewModifier {
  var offset: CGSize = .zero
  var scale: CGFloat = 1
  var opacity: Double = 1
  var landingFade: Animation?

  static let rest = FirstLaunchFlight()
  static let fade = FirstLaunchFlight(opacity: 0)

  func body(content: Content) -> some View {
    content
      .scaleEffect(scale)
      .offset(offset)
      .animation(landingFade) { $0.opacity(opacity) }
  }

  static func toward(_ target: CGRect?, from frame: CGRect?, scale: CGFloat) -> FirstLaunchFlight {
    guard let target, let frame else { return .fade }
    let offset = CGSize(width: target.midX - frame.midX, height: target.midY - frame.midY)
    return FirstLaunchFlight(offset: offset, scale: scale, opacity: 0, landingFade: landing)
  }

  private static let landing = Animation.easeIn(duration: 0.18).delay(0.42)
}
