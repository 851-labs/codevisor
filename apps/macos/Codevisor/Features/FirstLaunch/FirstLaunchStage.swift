import SwiftUI

struct FirstLaunchStage {
  let style: FirstLaunchDismissStyle
  let isLeaving: Bool
  let targets: [FirstLaunchLandingTarget: CGRect]
  let windowSize: CGSize
  let composerCornerRadius: CGFloat
}
