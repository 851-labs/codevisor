import AppKit

enum TitlebarDoubleClickAction: Equatable {
  case zoom
  case minimize
  case doNothing

  init(defaults: UserDefaults) {
    self.init(
      setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
      legacyMinimizes: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
    )
  }

  init(setting: String?, legacyMinimizes: Bool) {
    switch setting {
    case "Maximize": self = .zoom
    case "Minimize": self = .minimize
    case "None": self = .doNothing
    default: self = legacyMinimizes ? .minimize : .zoom
    }
  }

  func perform(on window: NSWindow) {
    switch self {
    case .zoom: window.zoom(nil)
    case .minimize: window.miniaturize(nil)
    case .doNothing: break
    }
  }
}
