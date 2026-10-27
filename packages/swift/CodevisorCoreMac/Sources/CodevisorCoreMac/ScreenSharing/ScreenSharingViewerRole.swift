public enum ScreenSharingViewerRole: Int, Comparable, Sendable {
  case watcher, tab, window

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
