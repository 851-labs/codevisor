import SwiftUI

public enum Typography {
  public static let minimumTextSize: CGFloat = {
    #if os(macOS)
      return 10
    #else
      return 11
    #endif
  }()

  public static let minimumInteractiveTargetSize: CGFloat = {
    #if os(macOS)
      return 20
    #else
      return 44
    #endif
  }()

  public enum IconSize {
    public static let disclosure: CGFloat = 10
    public static let compact: CGFloat = 10
    public static let chrome: CGFloat = 12
    public static let toolbar: CGFloat = 13
    public static let hero: CGFloat = 34
  }

  public enum DisplaySize {
    public static let heroTitle: CGFloat = 36
    public static let stepTitle: CGFloat = 28
    public static let emptyStateTitle: CGFloat = 26
  }

  public static let tabLabelSize: CGFloat = 11.5
}

extension Font {
  public static let heroTitle = Font.system(
    size: Typography.DisplaySize.heroTitle, weight: .bold
  )

  public static let stepTitle = Font.system(
    size: Typography.DisplaySize.stepTitle, weight: .bold
  )

  public static let emptyStateTitle = Font.system(
    size: Typography.DisplaySize.emptyStateTitle, weight: .semibold
  )

  public static func tabLabel(weight: Font.Weight = .regular) -> Font {
    .system(size: Typography.tabLabelSize, weight: weight)
  }
}
