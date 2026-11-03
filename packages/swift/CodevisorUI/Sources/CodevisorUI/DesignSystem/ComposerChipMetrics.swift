import CoreGraphics

public enum ComposerChipMetrics {
  public static let side: CGFloat = 96
  public static let size = CGSize(width: side, height: side)

  public static let cornerRadius: CGFloat = {
    #if os(macOS)
      12
    #else
      16
    #endif
  }()
}
