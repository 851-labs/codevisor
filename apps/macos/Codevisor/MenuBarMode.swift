import Foundation

enum MenuBarMode {
  static let defaultsKey = "CodevisorRunsInMenuBar"
  static let sandboxImageDefaultsKey = "CodevisorRunsAsSandbox"
  static let defaultsKeys = [defaultsKey, sandboxImageDefaultsKey]

  static let isEnabled = defaultsKeys.contains { UserDefaults.standard.bool(forKey: $0) }

  static func restart(enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: defaultsKey)
    UserDefaults.standard.removeObject(forKey: sandboxImageDefaultsKey)
    AppRelauncher.relaunch()
  }
}
