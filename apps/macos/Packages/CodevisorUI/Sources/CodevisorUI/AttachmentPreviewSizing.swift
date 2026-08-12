import CoreGraphics

/// Fits an intrinsic media aspect ratio inside transcript-friendly bounds.
/// The returned size preserves the ratio exactly and never exceeds either
/// maximum dimension.
public func boundedAttachmentPreviewSize(
    aspectRatio: CGFloat?,
    maximumSize: CGSize,
    fallbackAspectRatio: CGFloat = 16.0 / 9.0
) -> CGSize {
    let fallback = fallbackAspectRatio.isFinite && fallbackAspectRatio > 0
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
