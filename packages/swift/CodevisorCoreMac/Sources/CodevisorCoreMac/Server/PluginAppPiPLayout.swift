import CoreGraphics

public enum PluginAppPiPLayout {
  public static let defaultWidth: CGFloat = 360
  public static let minimumWidth: CGFloat = 240
  public static let minimumHeight: CGFloat = 80

  public static func size(
    width: CGFloat?,
    contentHeight: CGFloat,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> CGSize {
    let availableWidth = max(0, container.width - insets.leading - insets.trailing)
    let availableHeight = max(0, container.height - insets.top - insets.bottom)
    let widest = max(minimumWidth, availableWidth * ComputerUseLivePreviewLayout.maximumWidthFraction)
    let fitted = min(max(width ?? defaultWidth, minimumWidth), widest, availableWidth)
    let height = min(max(contentHeight, minimumHeight), max(minimumHeight, availableHeight))
    return CGSize(width: fitted.rounded(), height: height.rounded())
  }

  public static func resizedWidth(
    handle: ComputerUseLivePreviewResizeHandle,
    startWidth: CGFloat,
    translation: CGFloat
  ) -> CGFloat {
    max(minimumWidth, startWidth + handle.horizontal * translation)
  }
}
