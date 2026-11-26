public enum ScreenSharingLabPresentation: String, Sendable, CaseIterable {
  case standard
  case late
  case realign

  public nonisolated(unsafe) static var current = ScreenSharingLabPresentation.standard
}
