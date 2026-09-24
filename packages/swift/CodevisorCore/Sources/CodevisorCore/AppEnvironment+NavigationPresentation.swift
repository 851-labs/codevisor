import Foundation

extension AppEnvironment {
  /// Every machine navigation can show, as the launch and sync-indicator
  /// rules see it. The local machine counts only where this app runs one;
  /// on iOS it is a placeholder, not a machine with workspaces.
  public var navigationPresentationMachines: [NavigationPresentation.Machine] {
    // The store's revision moves whenever a cache is replaced or updated,
    // which is what `hasCache`/`isCacheEmpty` read.
    _ = navigationStore.revision
    let states = machines.navigationSyncStateByMachineId
    return machines.allMachines
      .filter { !$0.isLocal || localServer != nil }
      .map { machine in
        NavigationPresentation.Machine(
          name: machine.name,
          hasCache: navigationStore.hasCache(for: machine.id),
          cacheIsEmpty: navigationStore.isCacheEmpty(for: machine.id),
          syncState: states[machine.id] ?? .catchingUp)
      }
  }

  public var navigationRosterStatus: NavigationPresentation.RosterStatus {
    guard cloud.isCloudSignedIn else { return .none }
    return cloud.isRosterVerified ? .verified : .unverified
  }

  public var navigationSyncIndicator: NavigationPresentation.SyncIndicator {
    NavigationPresentation.indicator(machines: navigationPresentationMachines)
  }

  public func navigationLaunch(hasVisibleContent: Bool) -> NavigationPresentation.Launch {
    NavigationPresentation.launch(
      machines: navigationPresentationMachines, roster: navigationRosterStatus, hasVisibleContent: hasVisibleContent)
  }
}
