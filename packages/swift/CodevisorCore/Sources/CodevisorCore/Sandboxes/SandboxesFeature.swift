import Foundation

public enum SandboxesFeature {
  public static let preferenceKey = "featureFlags.sandboxes"

  @MainActor public static var isEnabled: Bool {
    ClientPreferences.shared.value(forKey: preferenceKey, default: false)
  }
}
