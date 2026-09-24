import Foundation

/// What the home screen shows at launch and whether to show a sync indicator,
/// decided from what the device already knows rather than from the network.
///
/// The rules the user sees:
/// - anything cached for any machine shows immediately, with an indicator
///   while machines catch up;
/// - a spinner only when there is nothing cached at all and a machine is
///   still being reached;
/// - "No Workspaces" only when every machine that answered said so.
public enum NavigationPresentation {
  public struct Machine: Equatable, Sendable {
    public var name: String
    public var hasCache: Bool
    public var cacheIsEmpty: Bool
    public var syncState: NavigationSyncState

    public init(name: String, hasCache: Bool, cacheIsEmpty: Bool, syncState: NavigationSyncState) {
      self.name = name
      self.hasCache = hasCache
      self.cacheIsEmpty = cacheIsEmpty
      self.syncState = syncState
    }

    var isUnreachable: Bool {
      if case .stale = syncState { return true }
      return false
    }
  }

  /// Whether the list of cloud machines is known yet.
  public enum RosterStatus: Equatable, Sendable {
    /// No cloud account: the machine list is whatever is on this device.
    case none
    /// A cached list is showing but hasn't been confirmed this launch.
    case unverified
    case verified
  }

  public enum Launch: Equatable, Sendable {
    case onboarding
    case loading
    case empty
    case content
  }

  public struct SyncIndicator: Equatable, Sendable {
    public var isSyncing: Bool
    public var unreachableMachineNames: [String]

    public static let hidden = SyncIndicator(isSyncing: false, unreachableMachineNames: [])

    public var isVisible: Bool { isSyncing || !unreachableMachineNames.isEmpty }

    /// One short line for a toolbar or sidebar footer.
    public var label: String? {
      if !unreachableMachineNames.isEmpty {
        return "Can't reach \(ListFormatter.localizedString(byJoining: unreachableMachineNames))"
      }
      return isSyncing ? "Syncing…" : nil
    }
  }

  public static func launch(
    machines: [Machine], roster: RosterStatus, hasVisibleContent: Bool
  ) -> Launch {
    if hasVisibleContent { return .content }
    if machines.isEmpty { return roster == .unverified ? .loading : .onboarding }
    // Certain only once every machine has answered with an empty list, or
    // can't be reached and was empty when it last answered.
    let everyMachineAnswered = machines.allSatisfy { machine in
      machine.syncState == .current || (machine.isUnreachable && machine.hasCache)
    }
    if everyMachineAnswered, machines.allSatisfy(\.cacheIsEmpty) { return .empty }
    // Nothing more will arrive: every machine is unreachable. Showing the
    // empty state (with the indicator naming them) beats spinning forever.
    if machines.allSatisfy({ $0.isUnreachable || $0.syncState == .current }) { return .empty }
    return .loading
  }

  public static func indicator(machines: [Machine]) -> SyncIndicator {
    SyncIndicator(
      isSyncing: machines.contains { $0.syncState == .cached || $0.syncState == .catchingUp },
      unreachableMachineNames: machines.filter(\.isUnreachable).map(\.name).sorted())
  }
}
