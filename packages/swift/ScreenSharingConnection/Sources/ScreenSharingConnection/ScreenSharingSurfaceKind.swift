public enum ScreenSharingSurfaceKind: Equatable, Sendable {
  case tab
  case window
  case phone
  case preview
  case pictureInPicture

  var opensTheDesktop: Bool {
    switch self {
    case .tab, .window, .phone: true
    case .preview, .pictureInPicture: false
    }
  }
}
