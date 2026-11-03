public enum PluginAppFullscreen: Equatable, Sendable {
  case unavailable
  case tab
  case split

  var defaultPlacement: PluginAppPanePlacement? {
    switch self {
    case .tab: .tab
    case .split: .split
    case .unavailable: nil
    }
  }
}

public enum PluginAppPanePlacement: Equatable, Sendable {
  case tab
  case split
}
