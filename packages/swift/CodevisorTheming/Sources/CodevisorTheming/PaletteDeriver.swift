import Foundation

public enum PaletteDeriver {
  private static let borderMix = 0.22

  public static func derive(from theme: VSCodeTheme) -> DerivedPalette? {
    let raw = theme.colors ?? [:]
    let resolved = ThemeNormalizer.normalize(theme).colors ?? [:]

    let sidebarBgHex = resolved["sideBar.background"]
    guard let sidebarBg = sidebarBgHex.flatMap({ RGBA(css: $0) }) else { return nil }
    guard
      let fgHex = ColorMath.pickReadableForeground(
        bg: sidebarBgHex,
        candidates: [raw["sideBar.foreground"], raw["editor.foreground"], theme.fg]
      ),
      let fgRaw = RGBA(css: fgHex)
    else { return nil }
    let fg = fgRaw.compositedOver(sidebarBg)

    let editorBg =
      resolved["editor.background"].flatMap { RGBA(css: $0) }?.compositedOver(sidebarBg)
      ?? sidebarBg
    let editorFg =
      resolved["editor.foreground"].flatMap { RGBA(css: $0) }?.compositedOver(editorBg)
      ?? fg

    let isDark = ColorMath.isDarkSurface(bg: sidebarBg.hexString(), fgHint: fg.hexString())

    let textSecondary =
      readableMuted(raw["descriptionForeground"], over: sidebarBg)
      ?? mutedFg(from: fg, over: sidebarBg)

    let borderOpaque = fg.mixed(with: sidebarBg, weight: borderMix)
    let separator =
      ColorMath.surfacesMatch(editorBg.hexString(), sidebarBg.hexString())
      ? borderOpaque
      : editorFg.mixed(with: editorBg, weight: borderMix)

    let focusRing =
      resolved["list.focusOutline"].flatMap { RGBA(css: $0) }?.compositedOver(sidebarBg)
      ?? fg

    let authoredAccent = contrastingThemeColor(
      resolved,
      keys: ["focusBorder", "textLink.foreground", "button.background", "list.focusOutline"],
      over: [sidebarBg],
      minRatio: ColorMath.minReadableRatio
    )
    let accent = authoredAccent ?? focusRing

    let rowHover = hoverRowFill(
      resolved, authoredAccent: authoredAccent, isDark: isDark, text: fg, base: sidebarBg)
    let rowSelected = selectedRowFill(
      resolved, authoredAccent: authoredAccent, isDark: isDark, text: fg, base: sidebarBg)

    let elevated = elevatedSurfaces(
      resolved, editorBg: editorBg, sidebarBg: sidebarBg, fg: fg)

    let statusSurfaces = [sidebarBg, editorBg, elevated.card]
    let status = statusColors(resolved, surfaces: statusSurfaces, isDark: isDark)

    let diff = diffBases(resolved, editorBg: editorBg, isDark: isDark)
    let diffRowMix = isDark ? 0.8 : 0.88

    return DerivedPalette(
      isDark: isDark,
      windowBackground: editorBg,
      sidebarBackground: sidebarBg,
      cardBackground: elevated.card,
      cardHoverBackground: elevated.cardHover,
      codeBackground: elevated.code,
      cardBorder: fg.mixed(with: sidebarBg, weight: 0.12),
      popoverBackground: elevated.popover,
      popoverBorder: fg.mixed(with: sidebarBg, weight: 0.18),
      composerBackground: editorBg,
      bubbleBackground: fg.mixed(with: sidebarBg, weight: 0.08),
      paneHeaderBackground: fg.mixed(with: editorBg, weight: 0.06),
      textPrimary: fg,
      textSecondary: textSecondary,
      textTertiary: fg.mixed(with: sidebarBg, weight: 0.45),
      rowHoverBackground: rowHover,
      rowSelectedBackground: rowSelected,
      accent: accent,
      focusRing: focusRing,
      border: fg.withAlpha(0.2),
      borderOpaque: borderOpaque,
      separator: separator,
      statusOK: status.ok,
      statusWarn: status.warn,
      statusError: status.error,
      diffAddedFg: diff.addition,
      diffRemovedFg: diff.deletion,
      diffAddedBg: editorBg.mixed(with: diff.addition, weight: diffRowMix),
      diffRemovedBg: editorBg.mixed(with: diff.deletion, weight: diffRowMix),
      diffLineNumberFg: editorFg.mixed(with: editorBg, weight: 0.65),
      terminal: terminalPalette(resolved: resolved, editorBg: editorBg, editorFg: editorFg)
    )
  }

  private static func hoverRowFill(
    _ resolved: [String: String], authoredAccent: RGBA?, isDark: Bool, text: RGBA, base: RGBA
  ) -> RGBA {
    return
      themeColor(resolved, keys: ["list.hoverBackground"], over: base)
      ?? authoredAccent.flatMap {
        accentRowFill($0, alpha: isDark ? 0.14 : 0.10, text: text, base: base)
      }
      ?? text.mixed(with: base, weight: 0.08)
  }

  private static func selectedRowFill(
    _ resolved: [String: String], authoredAccent: RGBA?, isDark: Bool, text: RGBA, base: RGBA
  ) -> RGBA {
    return
      themeColor(resolved, keys: ["list.activeSelectionBackground"], over: base)
      .flatMap { usableRowFill($0, text: text, base: base) ? $0 : nil }
      ?? authoredAccent.flatMap {
        accentRowFill($0, alpha: isDark ? 0.28 : 0.22, text: text, base: base)
      }
      ?? text.mixed(with: base, weight: 0.14)
  }

  private static func statusColors(
    _ resolved: [String: String], surfaces: [RGBA], isDark: Bool
  ) -> (ok: RGBA, warn: RGBA, error: RGBA) {
    let statusOK =
      contrastingThemeColor(
        resolved,
        keys: [
          "terminal.ansiGreen", "terminal.ansiBrightGreen",
          "gitDecoration.addedResourceForeground",
        ],
        over: surfaces, minRatio: ColorMath.minReadableRatio
      ) ?? constant(isDark ? "#34d399" : "#047857")
    let statusWarn =
      contrastingThemeColor(
        resolved,
        keys: [
          "terminal.ansiYellow", "terminal.ansiBrightYellow",
          "editorWarning.foreground",
        ],
        over: surfaces, minRatio: ColorMath.minReadableRatio
      ) ?? constant(isDark ? "#f59e0b" : "#b45309")
    let statusError =
      contrastingThemeColor(
        resolved,
        keys: [
          "terminal.ansiRed", "terminal.ansiBrightRed",
          "editorError.foreground",
        ],
        over: surfaces, minRatio: ColorMath.minReadableRatio
      ) ?? constant(isDark ? "#fb7185" : "#be123c")
    return (ok: statusOK, warn: statusWarn, error: statusError)
  }

  private static func diffBases(
    _ resolved: [String: String], editorBg: RGBA, isDark: Bool
  ) -> (addition: RGBA, deletion: RGBA) {
    let additionBase =
      themeColor(
        resolved,
        keys: ["gitDecoration.addedResourceForeground", "terminal.ansiGreen"],
        over: editorBg
      ) ?? constant(isDark ? "#5ecc71" : "#0dbe4e")
    let deletionBase =
      themeColor(
        resolved,
        keys: ["gitDecoration.deletedResourceForeground", "terminal.ansiRed"],
        over: editorBg
      ) ?? constant(isDark ? "#ff6762" : "#ff2e3f")
    return (addition: additionBase, deletion: deletionBase)
  }

  private static func elevatedSurfaces(
    _ resolved: [String: String], editorBg: RGBA, sidebarBg: RGBA, fg: RGBA
  ) -> (card: RGBA, cardHover: RGBA, code: RGBA, popover: RGBA) {
    let authoredCard = authoredElevatedSurface(
      resolved, keys: ["editorWidget.background"], sidebarBg: sidebarBg, fg: fg)
    let cardBackground = authoredCard ?? fg.mixed(with: sidebarBg, weight: 0.06)
    let cardHoverBackground =
      authoredCard.map { fg.mixed(with: $0, weight: 0.06) }
      ?? fg.mixed(with: sidebarBg, weight: 0.12)
    let codeBackground =
      separated(cardBackground, from: editorBg)
      ? cardBackground
      : liftedSurface(from: fg, over: editorBg)
    let popoverBackground =
      authoredElevatedSurface(
        resolved,
        keys: ["menu.background", "editorWidget.background", "dropdown.background"],
        sidebarBg: sidebarBg, fg: fg
      ) ?? fg.mixed(with: sidebarBg, weight: 0.07)

    return (
      card: cardBackground, cardHover: cardHoverBackground,
      code: codeBackground, popover: popoverBackground
    )
  }

  private static func contrastingThemeColor(
    _ colors: [String: String], keys: [String],
    over surfaces: [RGBA], minRatio: Double
  ) -> RGBA? {
    guard let base = surfaces.first else { return nil }
    for key in keys {
      guard
        let hex = colors[key],
        !ColorMath.isFullyTransparent(hex),
        let color = RGBA(css: hex)
      else { continue }
      let composited = color.compositedOver(base)
      let clearsAll = surfaces.allSatisfy {
        ColorMath.contrastRatio($0.relativeLuminance, composited.relativeLuminance)
          >= minRatio
      }
      if clearsAll { return composited }
    }
    return nil
  }

  private static func usableRowFill(_ fill: RGBA, text: RGBA, base: RGBA) -> Bool {
    guard fill != base else { return false }
    return ColorMath.contrastRatio(fill.relativeLuminance, text.relativeLuminance)
      >= ColorMath.minReadableRatio
  }

  private static func accentRowFill(
    _ accent: RGBA, alpha: Double, text: RGBA, base: RGBA
  ) -> RGBA? {
    let fill = accent.withAlpha(alpha).compositedOver(base)
    return usableRowFill(fill, text: text, base: base) ? fill : nil
  }

  private static let minSurfaceDelta = 6.0

  private static func separated(_ fill: RGBA, from surface: RGBA) -> Bool {
    max(abs(fill.r - surface.r), abs(fill.g - surface.g), abs(fill.b - surface.b))
      >= minSurfaceDelta
  }

  private static func liftedSurface(from fg: RGBA, over base: RGBA) -> RGBA {
    let ladder = [0.06, 0.10, 0.16, 0.24]
    for weight in ladder {
      let fill = fg.mixed(with: base, weight: weight)
      if separated(fill, from: base) { return fill }
    }
    return fg.mixed(with: base, weight: ladder[ladder.count - 1])
  }

  private static func authoredElevatedSurface(
    _ colors: [String: String], keys: [String], sidebarBg: RGBA, fg: RGBA
  ) -> RGBA? {
    for key in keys {
      guard let hex = colors[key], let color = RGBA(css: hex) else { continue }
      let composited = color.compositedOver(sidebarBg)
      guard composited != sidebarBg else { continue }
      guard
        ColorMath.contrastRatio(
          composited.relativeLuminance, fg.relativeLuminance)
          >= ColorMath.minReadableRatio
      else { continue }
      return composited
    }
    return nil
  }

  private static func themeColor(
    _ colors: [String: String], keys: [String], over bg: RGBA
  ) -> RGBA? {
    for key in keys {
      if let hex = colors[key], let color = RGBA(css: hex) {
        return color.compositedOver(bg)
      }
    }
    return nil
  }

  private static func readableMuted(_ candidate: String?, over bg: RGBA) -> RGBA? {
    guard let candidate, let color = RGBA(css: candidate) else { return nil }
    let composited = color.compositedOver(bg)
    let ratio = ColorMath.contrastRatio(
      bg.relativeLuminance, composited.relativeLuminance)
    return ratio >= ColorMath.minMutedRatio ? composited : nil
  }

  private static func mutedFg(from fg: RGBA, over bg: RGBA) -> RGBA {
    let bgL = bg.relativeLuminance
    for weight in [0.6, 0.7, 0.8, 0.9] {
      let mixed = fg.mixed(with: bg, weight: weight)
      if ColorMath.contrastRatio(bgL, mixed.relativeLuminance) >= ColorMath.minMutedRatio {
        return mixed
      }
    }
    return fg
  }

  private static let ansiKeys = [
    "terminal.ansiBlack", "terminal.ansiRed", "terminal.ansiGreen",
    "terminal.ansiYellow", "terminal.ansiBlue", "terminal.ansiMagenta",
    "terminal.ansiCyan", "terminal.ansiWhite", "terminal.ansiBrightBlack",
    "terminal.ansiBrightRed", "terminal.ansiBrightGreen", "terminal.ansiBrightYellow",
    "terminal.ansiBrightBlue", "terminal.ansiBrightMagenta", "terminal.ansiBrightCyan",
    "terminal.ansiBrightWhite",
  ]

  private static func terminalPalette(
    resolved: [String: String],
    editorBg: RGBA,
    editorFg: RGBA
  ) -> TerminalPalette {
    let background =
      resolved["terminal.background"].flatMap { RGBA(css: $0) }?.compositedOver(editorBg)
      ?? editorBg
    let foreground =
      resolved["terminal.foreground"].flatMap { RGBA(css: $0) }?.compositedOver(background)
      ?? editorFg
    let cursor = (resolved["terminalCursor.foreground"] ?? resolved["editorCursor.foreground"])
      .flatMap { RGBA(css: $0) }?.compositedOver(background)
    let selectionBg = resolved["terminal.selectionBackground"]
      .flatMap { RGBA(css: $0) }?.compositedOver(background)
    let selectionFg = resolved["terminal.selectionForeground"]
      .flatMap { RGBA(css: $0) }
    return TerminalPalette(
      background: background,
      foreground: foreground,
      cursorColor: cursor,
      selectionBackground: selectionBg,
      selectionForeground: selectionFg,
      ansi: ansiKeys.map { key in
        resolved[key].flatMap { RGBA(css: $0) }?.compositedOver(background)
      }
    )
  }

  private static func constant(_ hex: String) -> RGBA {
    guard let color = RGBA(hex: hex) else {
      preconditionFailure("Invalid palette constant \(hex)")
    }
    return color
  }
}
