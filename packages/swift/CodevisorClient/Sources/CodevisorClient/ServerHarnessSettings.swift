import Foundation

public struct ServerHarnessPreference: Codable, Equatable, Sendable {
  public var enabled: Bool?
  public var installed: Bool?

  public init(enabled: Bool? = nil, installed: Bool? = nil) {
    self.enabled = enabled
    self.installed = installed
  }
}

public struct ServerHarnessSettings: Codable, Equatable, Sendable {
  public var global: ServerHarnessPreference?
  public var override: ServerHarnessPreference?

  public init(global: ServerHarnessPreference? = nil, override: ServerHarnessPreference? = nil) {
    self.global = global
    self.override = override
  }
}
