import Foundation

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

  public enum RosterStatus: Equatable, Sendable {
    case none
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
    let everyMachineAnswered = machines.allSatisfy { machine in
      machine.syncState == .current || (machine.isUnreachable && machine.hasCache)
    }
    if everyMachineAnswered, machines.allSatisfy(\.cacheIsEmpty) { return .empty }
    if machines.allSatisfy({ $0.isUnreachable || $0.syncState == .current }) { return .empty }
    return .loading
  }

  public static func indicator(machines: [Machine], hasVisibleContent: Bool = true) -> SyncIndicator {
    SyncIndicator(
      isSyncing: hasVisibleContent
        && machines.contains { $0.syncState == .cached || $0.syncState == .catchingUp },
      unreachableMachineNames: machines.filter(\.isUnreachable).map(\.name).sorted())
  }
}
