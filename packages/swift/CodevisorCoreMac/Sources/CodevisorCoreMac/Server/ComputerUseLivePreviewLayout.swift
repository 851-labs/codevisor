import CoreGraphics

public enum ComputerUseLivePreviewCorner: CaseIterable, Equatable, Sendable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing

  public var isTop: Bool { self == .topLeading || self == .topTrailing }
  public var isLeading: Bool { self == .topLeading || self == .bottomLeading }
}

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
  public static let margin: CGFloat = 12
  public static let composerTopPadding: CGFloat = 24

  public static func insets(composerHeight: CGFloat) -> ComputerUseLivePreviewInsets {
    ComputerUseLivePreviewInsets(
      top: margin,
      leading: margin,
      bottom: max(margin, composerHeight - composerTopPadding + margin),
      trailing: margin
    )
  }

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

public enum ComputerUseLivePreviewResizeHandle: CaseIterable, Equatable, Sendable {
  case top, bottom, leading, trailing
  case topLeading, topTrailing, bottomLeading, bottomTrailing

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
  public static let minimumShortSide: CGFloat = 120
  public static let minimumLongSide: CGFloat = 200
  public static let maximumWidthFraction: CGFloat = 0.6
  public static let defaultBounds = CGSize(width: 320, height: 260)

  public static func defaultArea(aspect: CGFloat) -> CGFloat {
    let size = computerUseLivePreviewSize(
      frameSize: CGSize(width: max(aspect, 0.01), height: 1),
      maxWidth: defaultBounds.width,
      maxHeight: defaultBounds.height
    )
    return size.width * size.height
  }

  public static func size(
    area: CGFloat,
    aspect: CGFloat,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> CGSize {
    let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 10.0
    let area = area.isFinite && area > 0 ? area : defaultArea(aspect: aspect)
    let landscape = aspect >= 1
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
    let hardMaximumWidth = max(minimumShortSide, min(availableWidth, availableWidth * maximumWidthFraction))
    width = min(width, hardMaximumWidth)
    height = min(max(height, minimumShortSide), max(minimumShortSide, availableHeight))
    return CGSize(width: width.rounded(), height: height.rounded())
  }

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
  public static let minimumCursorScale: CGFloat = 0.5
  public static let maximumCursorScale: CGFloat = 1

  public static func cursorScale(cardWidth: CGFloat, windowWidth: CGFloat) -> CGFloat {
    guard cardWidth.isFinite, windowWidth.isFinite, cardWidth > 0, windowWidth > 0 else {
      return maximumCursorScale
    }
    return min(maximumCursorScale, max(minimumCursorScale, cardWidth / windowWidth))
  }
}
