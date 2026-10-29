import Foundation

public enum LocalNetworkAccess: String, Codable, Sendable {
  case unasked
  case requested
  case deferred

  static let preferenceKey = "localNetwork.access"
  static let requestedPreferenceKey = "localNetwork.requested"
}

extension AppEnvironment {
  public var localNetworkAccess: LocalNetworkAccess {
    preferences.value(forKey: LocalNetworkAccess.preferenceKey, default: .unasked)
  }

  public var needsLocalNetworkChoice: Bool {
    localNetworkAccess == .unasked
  }

  public var hasRequestedLocalNetworkAccess: Bool {
    let requested = preferences.valueIfPresent(
      forKey: LocalNetworkAccess.requestedPreferenceKey,
      as: Bool.self
    )
    return localNetworkAccess == .requested || requested == true
  }

  public func setLocalNetworkAccess(_ access: LocalNetworkAccess) {
    preferences.set(access, forKey: LocalNetworkAccess.preferenceKey)
    if access == .requested {
      preferences.set(true, forKey: LocalNetworkAccess.requestedPreferenceKey)
    }
    applyLocalNetworkAccess()
    syncLocalServerDirectPaths()
  }

  func applyLocalNetworkAccess() {
    cloud.directPaths.setAllowsDirectPaths(localNetworkAccess == .requested)
  }

  func syncLocalServerDirectPaths() {
    guard localServer != nil else { return }
    let allowed = localNetworkAccess == .requested
    let client = machines.client(for: CodevisorMachine.local.id)
    let previous = localServerDirectPathsSync
    localServerDirectPathsSync = Task {
      await previous?.value
      do {
        try await client.setCloudDirectPaths(allowed)
      } catch {
        Log.cloud.debug(
          "Local server direct paths not updated: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
