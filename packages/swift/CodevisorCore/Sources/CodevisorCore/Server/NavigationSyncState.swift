public enum NavigationSyncState: Equatable, Sendable {
  case cached
  case catchingUp
  case current
  case stale(String)
}

enum NavigationSyncPresentation: Equatable, Sendable {
  case background
  case catchUp
}

public enum ServerNavigationRefreshResult: Sendable, Equatable {
  case committed
  case superseded
  case failed(String)
}
