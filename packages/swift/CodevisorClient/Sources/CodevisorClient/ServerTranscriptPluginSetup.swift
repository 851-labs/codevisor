import ACPKit
import Foundation
import TranscriptKit

public struct ServerTranscriptPluginSetup: Decodable, Equatable, Sendable {
  public var id: String
  public var state: String
  public var request: JSONValue

  var transcriptInteraction: TranscriptInteraction? {
    guard let state = PluginSetupUpdate.State(rawValue: state) else { return nil }
    return TranscriptInteraction(
      id: id, content: .pluginSetup(TranscriptPluginSetup(id: id, state: state, request: request)))
  }
}
