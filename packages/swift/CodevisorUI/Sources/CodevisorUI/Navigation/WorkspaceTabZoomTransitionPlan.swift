import CoreGraphics
import Foundation

/// One visual endpoint for the workspace-local tab zoom.
///
/// The mask owns the changing surface shape. The canvas keeps the snapshot in
/// one immutable coordinate system and is moved with a *uniform* scale plus a
/// translation. Keeping those two pieces independent is what prevents text,
/// rows, and controls from being squeezed or re-laid-out as the card changes
/// aspect ratio.
public struct WorkspaceTabZoomTransitionEndpoint: Equatable, Sendable {
  public let maskFrame: CGRect
  public let canvasOrigin: CGPoint
  public let canvasScale: CGFloat
  public let cornerRadius: CGFloat

  public init(
    maskFrame: CGRect,
    canvasOrigin: CGPoint,
    canvasScale: CGFloat,
    cornerRadius: CGFloat
  ) {
    self.maskFrame = maskFrame
    self.canvasOrigin = canvasOrigin
    self.canvasScale = canvasScale
    self.cornerRadius = cornerRadius
  }

  /// The snapshot's bounds after its uniform transform, in window space.
  public func renderedCanvasFrame(canvasSize: CGSize) -> CGRect {
    CGRect(
      origin: canvasOrigin,
      size: CGSize(
        width: canvasSize.width * canvasScale,
        height: canvasSize.height * canvasScale
      )
    )
  }
}

/// Geometry and timing for the workspace-local tab zoom.
///
/// Navigation ownership deliberately stays outside this contract: the grid
/// and active pane remain two states of the same WorkspaceScreen. iOS uses
/// this plan only to transform a temporary fixed-resolution pixel canvas and
/// its independent clipping mask between those states.
public struct WorkspaceTabZoomTransitionPlan: Equatable, Sendable {
  public let canvasSize: CGSize
  public let source: WorkspaceTabZoomTransitionEndpoint
  public let destination: WorkspaceTabZoomTransitionEndpoint
  public let duration: TimeInterval

  public init(
    canvasSize: CGSize,
    source: WorkspaceTabZoomTransitionEndpoint,
    destination: WorkspaceTabZoomTransitionEndpoint,
    duration: TimeInterval
  ) {
    self.canvasSize = canvasSize
    self.source = source
    self.destination = destination
    self.duration = duration
  }
}

public enum WorkspaceTabZoomDirection: Sendable {
  case paneToGrid
  case gridToPane
}

public enum WorkspaceTabZoomTransitionContract {
  /// Safari's zoom responds immediately and settles quickly. The previous
  /// 460 ms spring plus a 92%-delayed handoff made even successful taps feel
  /// queued behind the animation.
  public static let duration: TimeInterval = 0.28
  public static let cardCornerRadius: CGFloat = 16
  public static let dampingRatio: CGFloat = 0.93
  public static let handoffDelayFactor: CGFloat = 0.84
  /// A generated placeholder has no live pixels to match mid-flight. Keep
  /// it authoritative until the mask reaches the full pane, then replace it
  /// atomically with the live UI instead of revealing a spinner early.
  public static let uncachedHandoffDelayFactor: CGFloat = 1

  /// Positions an uncached pane's placeholder so its uniformly scaled
  /// canvas begins with the symbol centered in the grid card. This avoids a
  /// one-frame jump when the temporary canvas covers the live placeholder.
  public static func uncachedPlaceholderSymbolCenterY(
    canvasSize: CGSize,
    cardSize: CGSize
  ) -> CGFloat? {
    guard canvasSize.isUsableTransitionSize,
      cardSize.isUsableTransitionSize
    else { return nil }
    let scale = max(
      cardSize.width / canvasSize.width,
      cardSize.height / canvasSize.height
    )
    return cardSize.height / (2 * scale)
  }

  /// Produces the two-way plan from one pair of canonical frames. Reversing
  /// direction swaps the endpoints exactly, so opening and closing cannot
  /// drift into subtly different geometry over time.
  public static func plan(
    direction: WorkspaceTabZoomDirection,
    viewportFrame: CGRect,
    cardFrame: CGRect,
    canvasSize: CGSize,
    reduceMotion: Bool = false
  ) -> WorkspaceTabZoomTransitionPlan? {
    guard !reduceMotion,
      viewportFrame.isUsableTransitionFrame,
      cardFrame.isUsableTransitionFrame,
      canvasSize.isUsableTransitionSize,
      viewportFrame.intersects(cardFrame)
    else { return nil }

    let pane = endpoint(
      maskFrame: viewportFrame,
      canvasSize: canvasSize,
      cornerRadius: 0
    )
    let card = endpoint(
      maskFrame: cardFrame,
      canvasSize: canvasSize,
      cornerRadius: cardCornerRadius
    )

    switch direction {
    case .paneToGrid:
      return WorkspaceTabZoomTransitionPlan(
        canvasSize: canvasSize,
        source: pane,
        destination: card,
        duration: duration
      )
    case .gridToPane:
      return WorkspaceTabZoomTransitionPlan(
        canvasSize: canvasSize,
        source: card,
        destination: pane,
        duration: duration
      )
    }
  }

  /// Aspect-fill the immutable canvas into `maskFrame`, aligned to the
  /// mask's top edge just like the tab preview. Only this uniform transform
  /// changes during the transition; the canvas bounds never do.
  private static func endpoint(
    maskFrame: CGRect,
    canvasSize: CGSize,
    cornerRadius: CGFloat
  ) -> WorkspaceTabZoomTransitionEndpoint {
    let scale = max(
      maskFrame.width / canvasSize.width,
      maskFrame.height / canvasSize.height
    )
    let renderedWidth = canvasSize.width * scale
    return WorkspaceTabZoomTransitionEndpoint(
      maskFrame: maskFrame,
      canvasOrigin: CGPoint(
        x: maskFrame.midX - renderedWidth / 2,
        y: maskFrame.minY
      ),
      canvasScale: scale,
      cornerRadius: cornerRadius
    )
  }
}

private extension CGRect {
  var isUsableTransitionFrame: Bool {
    !isNull
      && !isInfinite
      && !isEmpty
      && minX.isFinite
      && minY.isFinite
      && width.isFinite
      && height.isFinite
  }
}

private extension CGSize {
  var isUsableTransitionSize: Bool {
    width.isFinite
      && height.isFinite
      && width > 0
      && height > 0
  }
}
