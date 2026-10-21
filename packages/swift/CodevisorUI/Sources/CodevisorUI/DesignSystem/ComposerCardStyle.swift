import SwiftUI

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

  public var cornerRadius: CGFloat {
    actionRadius + Self.contentPadding
  }

  public var shape: ConcentricRectangle {
    insetShape(by: 0)
  }

  public var containerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius)
  }

  public var buttonBorderShape: ButtonBorderShape {
    #if os(macOS)
      .capsule
    #else
      .automatic
    #endif
  }

  public func insetShape(by inset: CGFloat) -> ConcentricRectangle {
    ConcentricRectangle(
      corners: .concentric(minimum: .fixed(max(0, cornerRadius - inset))),
      isUniform: true
    )
  }
}
