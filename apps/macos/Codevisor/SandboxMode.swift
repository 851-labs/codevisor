import Foundation

enum SandboxMode {
  static let defaultsKey = "CodevisorRunsAsSandbox"

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }
}
