import SwiftUI

/// Matches iOS's concentric corners using the macOS composer's control sizes.
struct ComposerCardStyle: DynamicProperty {
  static let contentPadding: CGFloat = 12
  static let actionDiameter: CGFloat = 26

  @ScaledMetric(relativeTo: .subheadline) private var actionRadius: CGFloat = actionDiameter / 2

  var shape: ConcentricRectangle {
    ConcentricRectangle(
      corners: .concentric(minimum: .fixed(actionRadius + Self.contentPadding)),
      isUniform: true
    )
  }
}
