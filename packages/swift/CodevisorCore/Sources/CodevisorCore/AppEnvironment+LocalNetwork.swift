import Foundation

public enum LocalNetworkAccess: String, Codable, Sendable {
  case unasked
  case requested
  case deferred

  static let preferenceKey = "localNetwork.access"
}

extension AppEnvironment {
  public var localNetworkAccess: LocalNetworkAccess? {
    ClientPreferences.shared.valueIfPresent(forKey: LocalNetworkAccess.preferenceKey)
  }

  public var needsLocalNetworkChoice: Bool {
    localNetworkAccess == .unasked
  }

  public func setLocalNetworkAccess(_ access: LocalNetworkAccess) {
    ClientPreferences.shared.set(access, forKey: LocalNetworkAccess.preferenceKey)
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
