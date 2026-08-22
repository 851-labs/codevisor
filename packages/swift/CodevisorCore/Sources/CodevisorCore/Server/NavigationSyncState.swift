/// The freshness of the selected machine's cached navigation projection.
/// Connectivity and synchronization are deliberately separate: a server can
/// answer health checks while its projects, sessions, and workspaces are still
/// being reconciled.
public enum NavigationSyncState: Equatable, Sendable {
    case cached
    case catchingUp
    case current
    case stale(String)
}

/// Whether a reconciliation should replace the navigation projection while it
/// runs. Live events and pull to refresh already have their own presentation;
/// only lifecycle recovery needs the blocking catch-up state.
enum NavigationSyncPresentation: Equatable, Sendable {
    case background
    case catchUp
}

/// Whether an authoritative project/session snapshot actually reached the
/// client cache. Callers use this to distinguish a completed reconciliation
/// from cached data that merely remained visible after a failed request.
public enum ServerNavigationRefreshResult: Sendable, Equatable {
    case committed
    case superseded
    case failed(String)
}
