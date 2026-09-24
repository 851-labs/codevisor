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

// MARK: - Resizing

/// An edge or corner the card is resized from.
public enum ComputerUseLivePreviewResizeHandle: CaseIterable, Equatable, Sendable {
  case top, bottom, leading, trailing
  case topLeading, topTrailing, bottomLeading, bottomTrailing

  /// -1, 0 or +1: which way along each axis dragging grows the card.
  public var horizontal: CGFloat {
    switch self {
    case .leading, .topLeading, .bottomLeading: -1
    case .trailing, .topTrailing, .bottomTrailing: 1
    case .top, .bottom: 0
    }
  }

  public var vertical: CGFloat {
    switch self {
    case .top, .topLeading, .topTrailing: -1
    case .bottom, .bottomLeading, .bottomTrailing: 1
    case .leading, .trailing: 0
    }
  }
}

extension ComputerUseLivePreviewLayout {
  /// The shorter side never goes below this, so the video stays legible.
  public static let minimumShortSide: CGFloat = 120
  /// The longer side never goes below this, so the glass close button fits.
  public static let minimumLongSide: CGFloat = 200
  /// The card never takes more than this share of the pane's width.
  public static let maximumWidthFraction: CGFloat = 0.6
  /// The size a new card starts at, before the user resizes it.
  public static let defaultBounds = CGSize(width: 320, height: 260)

  /// The area of a card aspect-fitted into the default bounds.
  public static func defaultArea(aspect: CGFloat) -> CGFloat {
    let size = computerUseLivePreviewSize(
      frameSize: CGSize(width: max(aspect, 0.01), height: 1),
      maxWidth: defaultBounds.width,
      maxHeight: defaultBounds.height
    )
    return size.width * size.height
  }

  /// The card's size for a preferred `area` at the stream's `aspect`
  /// (width ÷ height), clamped to the limits. Storing an area rather than a
  /// width keeps the card about as large when the controlled window switches
  /// between portrait and landscape. Where the limits cannot all hold at
  /// that aspect, they win and the video letterboxes inside the card.
  public static func size(
    area: CGFloat,
    aspect: CGFloat,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> CGSize {
    let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 10.0
    let area = area.isFinite && area > 0 ? area : defaultArea(aspect: aspect)
    let landscape = aspect >= 1
    // Aspect-locked width range.
    let minimumWidth =
      landscape
      ? max(minimumLongSide, minimumShortSide * aspect)
      : max(minimumShortSide, minimumLongSide * aspect)
    let availableWidth = max(0, container.width - insets.leading - insets.trailing)
    let availableHeight = max(0, container.height - insets.top - insets.bottom)
    let maximumWidth = min(availableWidth * maximumWidthFraction, availableHeight * aspect)
    var width = (area * aspect).squareRoot()
    width = min(max(width, minimumWidth), max(minimumWidth, maximumWidth))
    var height = width / aspect
    // Hard bounds: never beyond the pane, never a sliver.
    let hardMaximumWidth = max(minimumShortSide, min(availableWidth, availableWidth * maximumWidthFraction))
    width = min(width, hardMaximumWidth)
    height = min(max(height, minimumShortSide), max(minimumShortSide, availableHeight))
    return CGSize(width: width.rounded(), height: height.rounded())
  }

  /// The area after dragging `handle` by `translation` from a card that
  /// started at `startSize`. Dragging outward grows the card; a corner
  /// follows whichever axis moved further, keeping the aspect locked.
  public static func resizedArea(
    handle: ComputerUseLivePreviewResizeHandle,
    startSize: CGSize,
    translation: CGSize,
    aspect: CGFloat
  ) -> CGFloat {
    let aspect = aspect.isFinite && aspect > 0 ? aspect : startSize.width / max(startSize.height, 1)
    let byWidth = handle.horizontal * translation.width
    let byHeight = handle.vertical * translation.height * aspect
    let widthDelta: CGFloat
    switch (handle.horizontal != 0, handle.vertical != 0) {
    case (true, true): widthDelta = abs(byWidth) >= abs(byHeight) ? byWidth : byHeight
    case (true, false): widthDelta = byWidth
    default: widthDelta = byHeight
    }
    let width = max(1, startSize.width + widthDelta)
    return width * (width / aspect)
  }
}

extension ComputerUseLivePreviewLayout {
  /// Smallest agent-pointer scale in the card, so it stays legible when the
  /// card is much smaller than the window it shows.
  public static let minimumCursorScale: CGFloat = 0.5
  /// Largest agent-pointer scale: never bigger than it is on screen.
  public static let maximumCursorScale: CGFloat = 1

  /// Scale for the agent pointer drawn over the card: the card's zoom of the
  /// streamed window, so the pointer keeps its on-screen size relative to the
  /// window, clamped to stay legible.
  public static func cursorScale(cardWidth: CGFloat, windowWidth: CGFloat) -> CGFloat {
    guard cardWidth.isFinite, windowWidth.isFinite, cardWidth > 0, windowWidth > 0 else {
      return maximumCursorScale
    }
    return min(maximumCursorScale, max(minimumCursorScale, cardWidth / windowWidth))
  }
}
