import ACPKit

public struct TranscriptPluginSetup: Sendable, Equatable {
  public var id: String
  public var state: PluginSetupUpdate.State
  public var request: JSONValue

  public init(id: String, state: PluginSetupUpdate.State, request: JSONValue) {
    self.id = id
    self.state = state
    self.request = request
  }

  public init(_ update: PluginSetupUpdate) {
    self.init(id: update.setupId, state: update.state, request: update.request)
  }
}
