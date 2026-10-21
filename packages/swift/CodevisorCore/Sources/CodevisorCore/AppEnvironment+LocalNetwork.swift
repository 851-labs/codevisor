import Foundation

public enum LocalNetworkAccess: String, Codable, Sendable {
  case unasked
  case requested
  case deferred

  static let preferenceKey = "localNetwork.access"
  static let requestedPreferenceKey = "localNetwork.requested"
}

extension AppEnvironment {
  public var localNetworkAccess: LocalNetworkAccess? {
    ClientPreferences.shared.valueIfPresent(forKey: LocalNetworkAccess.preferenceKey)
  }

  public var needsLocalNetworkChoice: Bool {
    localNetworkAccess == .unasked
  }

  public var hasRequestedLocalNetworkAccess: Bool {
    let requested = ClientPreferences.shared.valueIfPresent(
      forKey: LocalNetworkAccess.requestedPreferenceKey,
      as: Bool.self
    )
    return localNetworkAccess == .requested || requested == true
  }

  public func setLocalNetworkAccess(_ access: LocalNetworkAccess) {
    ClientPreferences.shared.set(access, forKey: LocalNetworkAccess.preferenceKey)
    if access == .requested {
      ClientPreferences.shared.set(true, forKey: LocalNetworkAccess.requestedPreferenceKey)
    }
    cloud.directPaths.setAllowsDirectPaths(access == .requested)
  }

  public func bootstrapCloud() async {
    await cloud.bootstrap()
    guard localNetworkAccess == nil else { return }
    setLocalNetworkAccess(cloud.state.isSignedIn ? .requested : .unasked)
  }

  func applyLaunchLocalNetworkAccess() {
    if localNetworkAccess == nil, settings.hasCompletedOnboarding {
      ClientPreferences.shared.set(LocalNetworkAccess.requested, forKey: LocalNetworkAccess.preferenceKey)
    }
    cloud.directPaths.setAllowsDirectPaths(localNetworkAccess == .requested)
  }
}
