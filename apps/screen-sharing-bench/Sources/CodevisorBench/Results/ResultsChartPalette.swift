enum ResultsChartPalette {
  private static let light = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
  private static let dark = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]

  static var style: String {
    """
    .surface{fill:#fcfcfb}.ink{fill:#0b0b0b}.muted{fill:#52514e}\
    .line{fill:none;stroke:#52514e;stroke-width:1.5}.dot{fill:#0b0b0b}\(stages(light))\
    @media (prefers-color-scheme: dark){.surface{fill:#1a1a19}.ink{fill:#f0efec}.muted{fill:#c3c2b7}\
    .line{stroke:#c3c2b7}.dot{fill:#f0efec}\(stages(dark))}
    """
  }

  private static func stages(_ colors: [String]) -> String {
    colors.enumerated().map { ".s\($0){fill:\($1)}" }.joined()
  }
}
