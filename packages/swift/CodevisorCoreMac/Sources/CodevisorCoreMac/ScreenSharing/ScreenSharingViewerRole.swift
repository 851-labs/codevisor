import ScreenSharingConnection

public enum ScreenSharingViewerRole: Int, Comparable, Sendable {
  case watcher, tab, window

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var surfaceKind: ScreenSharingSurfaceKind {
    switch self {
    case .watcher: .preview
    case .tab: .tab
    case .window: .window
    }
  }
}
