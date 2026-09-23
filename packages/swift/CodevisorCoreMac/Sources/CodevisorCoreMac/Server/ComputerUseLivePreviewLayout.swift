import CoreGraphics

/// Where the live preview card rests in its chat pane, like native
/// picture-in-picture: always in one of the four corners.
public enum ComputerUseLivePreviewCorner: CaseIterable, Equatable, Sendable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing

  public var isTop: Bool { self == .topLeading || self == .topTrailing }
  public var isLeading: Bool { self == .topLeading || self == .bottomLeading }
}

/// The area the card may occupy: the pane minus its margins, where the
/// bottom margin clears the floating composer.
public struct ComputerUseLivePreviewInsets: Equatable, Sendable {
  public var top: CGFloat
  public var leading: CGFloat
  public var bottom: CGFloat
  public var trailing: CGFloat

  public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
    self.top = top
    self.leading = leading
    self.bottom = bottom
    self.trailing = trailing
  }
}

public enum ComputerUseLivePreviewLayout {
  /// Gap between the card and the pane edges or the composer.
  public static let margin: CGFloat = 12
  /// Transparent padding above the composer's visible top edge.
  public static let composerTopPadding: CGFloat = 24

  /// Insets for a pane whose floating composer occupies `composerHeight`
  /// (including its own transparent top padding) at the bottom.
  public static func insets(composerHeight: CGFloat) -> ComputerUseLivePreviewInsets {
    ComputerUseLivePreviewInsets(
      top: margin,
      leading: margin,
      bottom: max(margin, composerHeight - composerTopPadding + margin),
      trailing: margin
    )
  }

  /// The card's top-left origin when resting in `corner`. A pane too small
  /// for the card pins it to the top-leading edge of the allowed area rather
  /// than pushing it off screen.
  public static func origin(
    corner: ComputerUseLivePreviewCorner,
    cardSize: CGSize,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> CGPoint {
    let minX = insets.leading
    let minY = insets.top
    let maxX = max(minX, container.width - insets.trailing - cardSize.width)
    let maxY = max(minY, container.height - insets.bottom - cardSize.height)
    return CGPoint(x: corner.isLeading ? minX : maxX, y: corner.isTop ? minY : maxY)
  }

  /// The corner a card released with its center at `projectedCenter` settles
  /// into: the quadrant of the allowed area that center falls in. Pass the
  /// drag's predicted end location so a flick carries the card onward.
  public static func corner(
    projectedCenter: CGPoint,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> ComputerUseLivePreviewCorner {
    let midX = (insets.leading + container.width - insets.trailing) / 2
    let midY = (insets.top + container.height - insets.bottom) / 2
    let leading = projectedCenter.x < midX
    let top = projectedCenter.y < midY
    switch (top, leading) {
    case (true, true): return .topLeading
    case (true, false): return .topTrailing
    case (false, true): return .bottomLeading
    case (false, false): return .bottomTrailing
    }
  }
}
