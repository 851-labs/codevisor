import Foundation

public enum StandaloneServerPreference {
  public static let defaultsKey = "CodevisorUsesStandaloneServer"

  public static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }
}
