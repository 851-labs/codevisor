import Foundation

public struct PluginSetupUpdate: Sendable, Codable, Equatable {
  public enum State: String, Sendable, Codable, Equatable {
    case pending
    case connected
  }

  public var setupId: String
  public var state: State
  public var request: JSONValue

  public init(setupId: String, state: State, request: JSONValue) {
    self.setupId = setupId
    self.state = state
    self.request = request
  }
}
