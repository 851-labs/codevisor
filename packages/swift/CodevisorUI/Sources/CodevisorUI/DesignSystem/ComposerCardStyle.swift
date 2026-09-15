import SwiftUI

/// Shared geometry for the composer and its accessory cards. The minimum
/// radius follows the platform's circular action button plus its content inset;
/// nearby screen, sheet, and window corners can increase it concentrically.
public struct ComposerCardStyle: DynamicProperty {
  #if os(iOS)
    public static let contentPadding: CGFloat = 13
    public static let actionDiameter: CGFloat = 30
  #else
    public static let contentPadding: CGFloat = 12
    public static let actionDiameter: CGFloat = 26
  #endif

  @ScaledMetric(relativeTo: .subheadline) private var actionRadius: CGFloat = actionDiameter / 2

  public init() {}

  public var shape: ConcentricRectangle {
    insetShape(by: 0)
  }

  /// Nested surfaces subtract their inset from the card's minimum radius,
  /// while resolving concentricity against the same screen or window.
  public func insetShape(by inset: CGFloat) -> ConcentricRectangle {
    ConcentricRectangle(
      corners: .concentric(minimum: .fixed(max(0, actionRadius + Self.contentPadding - inset))),
      isUniform: true
    )
  }
}
