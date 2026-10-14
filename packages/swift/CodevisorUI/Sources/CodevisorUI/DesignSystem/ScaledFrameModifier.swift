import SwiftUI

private struct ScaledFrameModifier: ViewModifier {
  @ScaledMetric private var scale: CGFloat
  private let width: CGFloat?
  private let height: CGFloat?
  private let alignment: Alignment

  init(
    width: CGFloat?,
    height: CGFloat?,
    relativeTo textStyle: Font.TextStyle,
    alignment: Alignment
  ) {
    self.width = width
    self.height = height
    self.alignment = alignment
    _scale = ScaledMetric(wrappedValue: 1, relativeTo: textStyle)
  }

  func body(content: Content) -> some View {
    content.frame(
      width: width.map { $0 * scale },
      height: height.map { $0 * scale },
      alignment: alignment
    )
  }
}

extension View {
  public func scaledFrame(
    width: CGFloat? = nil,
    height: CGFloat? = nil,
    relativeTo textStyle: Font.TextStyle = .body,
    alignment: Alignment = .center
  ) -> some View {
    modifier(
      ScaledFrameModifier(
        width: width,
        height: height,
        relativeTo: textStyle,
        alignment: alignment
      )
    )
  }
}

extension View {
  public func expandedHitTarget(base: CGFloat, minimum: CGFloat = 44) -> some View {
    let pad = max(0, (minimum - base) / 2)
    return padding(pad)
      .contentShape(Rectangle())
      .padding(-pad)
  }
}
