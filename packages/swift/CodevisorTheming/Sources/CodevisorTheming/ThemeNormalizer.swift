import Foundation

public enum ThemeNormalizer {
  public static func normalize(_ theme: VSCodeTheme) -> VSCodeTheme {
    let originalColors = theme.colors ?? [:]
    var colors = originalColors

    let editorBackground = originalColors["editor.background"] ?? theme.bg
    let editorForeground = originalColors["editor.foreground"] ?? theme.fg
    let sidebarBackground = originalColors["sideBar.background"] ?? editorBackground
    let sidebarForeground = originalColors["sideBar.foreground"] ?? editorForeground

    fillSurfaces(
      &colors, originalColors, editorBackground, editorForeground, sidebarBackground, sidebarForeground
    )
    fillGitDecorations(&colors, originalColors)
    repairFocusOutline(&colors, originalColors)
    repairHoverBackground(&colors, originalColors, sidebarBackground, sidebarForeground)
    repairSelectionBackground(&colors, originalColors, sidebarBackground, sidebarForeground)

    var result = theme
    result.colors = colors
    return result
  }

  private static func fillSurfaces(
    _ colors: inout [String: String],
    _ originalColors: [String: String],
    _ editorBackground: String?,
    _ editorForeground: String?,
    _ sidebarBackground: String?,
    _ sidebarForeground: String?
  ) {
    fill(&colors, "editor.background", editorBackground)
    fill(&colors, "editor.foreground", editorForeground)
    fill(&colors, "sideBar.background", sidebarBackground)
    fill(&colors, "sideBar.foreground", sidebarForeground)
    fill(&colors, "input.background", originalColors["input.background"] ?? sidebarBackground)
    fill(
      &colors,
      "sideBarSectionHeader.foreground",
      originalColors["sideBarSectionHeader.foreground"] ?? sidebarForeground
    )
    fill(
      &colors,
      "list.activeSelectionForeground",
      originalColors["list.activeSelectionForeground"] ?? sidebarForeground
    )
  }

  private static func fillGitDecorations(
    _ colors: inout [String: String],
    _ originalColors: [String: String]
  ) {
    fill(
      &colors,
      "gitDecoration.addedResourceForeground",
      firstColor(
        originalColors["gitDecoration.addedResourceForeground"],
        originalColors["terminal.ansiGreen"],
        originalColors["editorGutter.addedBackground"]
      )
    )
    fill(
      &colors,
      "gitDecoration.modifiedResourceForeground",
      firstColor(
        originalColors["gitDecoration.modifiedResourceForeground"],
        originalColors["terminal.ansiBlue"],
        originalColors["editorGutter.modifiedBackground"]
      )
    )
    fill(
      &colors,
      "gitDecoration.deletedResourceForeground",
      firstColor(
        originalColors["gitDecoration.deletedResourceForeground"],
        originalColors["terminal.ansiRed"],
        originalColors["editorGutter.deletedBackground"]
      )
    )
  }

  private static func repairFocusOutline(
    _ colors: inout [String: String],
    _ originalColors: [String: String]
  ) {
    let focusOutline = originalColors["list.focusOutline"]
    let focusBorder = originalColors["focusBorder"]
    let focusRing =
      (ColorMath.isFullyTransparent(focusOutline) ? nil : focusOutline)
      ?? (ColorMath.isFullyTransparent(focusBorder) ? nil : focusBorder)
    if let focusRing {
      colors["list.focusOutline"] = focusRing
    } else {
      colors.removeValue(forKey: "list.focusOutline")
    }
  }

  private static func repairHoverBackground(
    _ colors: inout [String: String],
    _ originalColors: [String: String],
    _ sidebarBackground: String?,
    _ sidebarForeground: String?
  ) {
    if let hover = originalColors["list.hoverBackground"],
      matchesSurface(hover, sidebarBackground)
        || ColorMath.hoverWouldEraseText(
          hover: hover, bg: sidebarBackground, fg: sidebarForeground)
    {
      colors.removeValue(forKey: "list.hoverBackground")
    }
  }

  private static func repairSelectionBackground(
    _ colors: inout [String: String],
    _ originalColors: [String: String],
    _ sidebarBackground: String?,
    _ sidebarForeground: String?
  ) {
    if let selection = originalColors["list.activeSelectionBackground"] {
      let effective =
        ColorMath.compositeOverBg(selection, over: sidebarBackground) ?? selection
      if ColorMath.isFullyTransparent(selection)
        || matchesSurface(selection, sidebarBackground)
        || matchesSurface(effective, sidebarBackground)
        || ColorMath.hoverWouldEraseText(
          hover: effective, bg: sidebarBackground, fg: sidebarForeground)
      {
        colors.removeValue(forKey: "list.activeSelectionBackground")
      }
    }
  }

  private static func fill(_ colors: inout [String: String], _ key: String, _ value: String?) {
    if let value, !value.isEmpty { colors[key] = value }
  }

  private static func firstColor(_ candidates: String?...) -> String? {
    candidates.compactMap { $0 }.first { !$0.isEmpty }
  }

  private static func matchesSurface(_ color: String, _ surface: String?) -> Bool {
    guard let surface else { return false }
    return color.lowercased() == surface.lowercased()
  }
}
