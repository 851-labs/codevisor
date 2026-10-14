#if os(macOS)
  import SwiftUI

  public enum SheetMetrics {
    case step
    case list
    case browser

    var width: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
      switch self {
      case .step: (440, 440, 520)
      case .list: (560, 560, 680)
      case .browser: (760, 760, 900)
      }
    }

    var height: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
      switch self {
      case .step: (240, 320, 560)
      case .list: (400, 460, 680)
      case .browser: (460, 540, 720)
      }
    }
  }

  extension View {
    public func sheetSize(_ metrics: SheetMetrics) -> some View {
      frame(
        minWidth: metrics.width.min, idealWidth: metrics.width.ideal, maxWidth: metrics.width.max,
        minHeight: metrics.height.min, idealHeight: metrics.height.ideal, maxHeight: metrics.height.max)
    }
  }
#endif
