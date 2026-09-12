import SwiftUI

/// Keeps the composer, goal, and queue cards equally rounded at every text size.
struct ComposerCardStyle: DynamicProperty {
  static let contentPadding: CGFloat = 13

  // Match the send button's 30-point diameter and Dynamic Type scaling.
  @ScaledMetric(relativeTo: .subheadline) private var sendButtonRadius: CGFloat = 15

  var shape: ConcentricRectangle {
    // Keep an even inset around the send button above the keyboard, while
    // allowing each card to follow a nearby screen or sheet corner.
    ConcentricRectangle(
      corners: .concentric(minimum: .fixed(sendButtonRadius + Self.contentPadding)),
      isUniform: true
    )
  }
}
