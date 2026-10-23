import SwiftUI

struct FirstLaunchMorph {
  let phase: FirstLaunchOverlayPhase
  let cardFrame: CGRect?
  let composerFrame: CGRect?
  let composerCornerRadius: CGFloat

  static let cardCornerRadius: CGFloat = 22
  static let contentFade = Animation.easeOut(duration: 0.15)

  var contentOpacity: Double {
    phase == .covering ? 1 : 0
  }

  var glass: FirstLaunchGlassShape {
    switch phase {
    case .covering, .gone: rest
    case .crossfading: FirstLaunchGlassShape(size: cardFrame?.size, cornerRadius: Self.cardCornerRadius, opacity: 0)
    case .morphing: morphed(opacity: 1) ?? rest
    case .revealing: morphed(opacity: 0) ?? rest
    }
  }

  private var rest: FirstLaunchGlassShape {
    FirstLaunchGlassShape(size: cardFrame?.size, cornerRadius: Self.cardCornerRadius)
  }

  private func morphed(opacity: Double) -> FirstLaunchGlassShape? {
    guard let composerFrame, let cardFrame else { return nil }
    let offset = CGSize(width: composerFrame.midX - cardFrame.midX, height: composerFrame.midY - cardFrame.midY)
    return FirstLaunchGlassShape(
      size: composerFrame.size,
      cornerRadius: composerCornerRadius,
      offset: offset,
      opacity: opacity
    )
  }
}
