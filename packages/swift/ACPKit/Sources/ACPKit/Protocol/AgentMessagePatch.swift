import Foundation

/// A position-addressed update to a persisted message. Offsets are UTF-16 code
/// units, matching the server. Replacements advance generation; appends do not.
public struct AgentMessagePatch: Codable, Equatable, Sendable {
  public var chatItemId: String? = nil
  public var messageId: String
  public var text: String
  public var offset: Int
  public var totalLength: Int
  public var generation: Int
  public var statePosition: Int?
  public var stateRevision: Int
  public var parentToolCallId: String?
  public var phase: MessagePhase?
  public var detailResource: ToolDetailResource?

  public init(
    messageId: String, text: String, offset: Int, totalLength: Int,
    generation: Int, stateRevision: Int, parentToolCallId: String? = nil,
    phase: MessagePhase? = nil, detailResource: ToolDetailResource? = nil, statePosition: Int? = nil
  ) {
    self.statePosition = statePosition
    self.messageId = messageId
    self.text = text
    self.offset = offset
    self.totalLength = totalLength
    self.generation = generation
    self.stateRevision = stateRevision
    self.parentToolCallId = parentToolCallId
    self.phase = phase
    self.detailResource = detailResource
  }
}
