import CoreGraphics

public struct AttachmentPreviewGeometryState: Sendable, Equatable {
  public private(set) var aspectRatio: CGFloat?
  public private(set) var isResolved = false

  public init() {}

  public mutating func resolve(
    aspectRatio candidate: CGFloat?,
    fallbackAspectRatio: CGFloat = 16.0 / 9.0
  ) {
    guard !isResolved else { return }
    let fallback =
      fallbackAspectRatio.isFinite && fallbackAspectRatio > 0
      ? fallbackAspectRatio
      : 16.0 / 9.0
    if let candidate, candidate.isFinite, candidate > 0 {
      aspectRatio = candidate
    } else {
      aspectRatio = fallback
    }
    isResolved = true
  }
}

public func boundedAttachmentPreviewSize(
  aspectRatio: CGFloat?,
  maximumSize: CGSize,
  fallbackAspectRatio: CGFloat = 16.0 / 9.0
) -> CGSize {
  let fallback =
    fallbackAspectRatio.isFinite && fallbackAspectRatio > 0
    ? fallbackAspectRatio
    : 16.0 / 9.0
  let ratio: CGFloat
  if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
    ratio = aspectRatio
  } else {
    ratio = fallback
  }
  let maxWidth = max(0, maximumSize.width)
  let maxHeight = max(0, maximumSize.height)

  guard maxWidth > 0, maxHeight > 0 else { return .zero }

  let widthAtMaximumHeight = maxHeight * ratio
  if widthAtMaximumHeight <= maxWidth {
    return CGSize(width: widthAtMaximumHeight, height: maxHeight)
  }
  return CGSize(width: maxWidth, height: maxWidth / ratio)
}
