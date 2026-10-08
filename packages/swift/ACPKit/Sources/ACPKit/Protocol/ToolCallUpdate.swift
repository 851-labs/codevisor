import Foundation

/// A partial update to an in-flight tool call. All fields except the id are optional.
public struct ToolCallUpdate: Sendable, Codable, Equatable {
  public var toolCallId: String
  public var title: String?
  public var kind: ToolKind?
  public var status: ToolCallStatus?
  public var content: [ToolCallContent]?
  public var locations: [ToolCallLocation]?
  public var rawInput: JSONValue?
  public var rawOutput: JSONValue?
  public var exitCode: Int?
  public var diffStats: [ToolCallDiffStat]?
  public var parentToolCallId: String?
  public var detailResource: ToolDetailResource?
  public var meta: JSONValue?

  public init(
    toolCallId: String,
    title: String? = nil,
    kind: ToolKind? = nil,
    status: ToolCallStatus? = nil,
    content: [ToolCallContent]? = nil,
    locations: [ToolCallLocation]? = nil,
    rawInput: JSONValue? = nil,
    rawOutput: JSONValue? = nil,
    exitCode: Int? = nil,
    diffStats: [ToolCallDiffStat]? = nil,
    parentToolCallId: String? = nil,
    detailResource: ToolDetailResource? = nil,
    meta: JSONValue? = nil
  ) {
    self.toolCallId = toolCallId
    self.title = title
    self.kind = kind
    self.status = status
    self.content = content
    self.locations = locations
    self.rawInput = rawInput
    self.rawOutput = rawOutput
    self.exitCode = exitCode
    self.diffStats = diffStats
    self.parentToolCallId = parentToolCallId
    self.detailResource = detailResource
    self.meta = meta
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: ToolCallKeys.self)
    toolCallId = try container.decode(String.self, forKey: .toolCallId)
    let fields = ToolCallFields(from: container)
    title = fields.title
    kind = fields.kind
    status = fields.status
    content = fields.content
    locations = fields.locations
    rawInput = fields.rawInput
    rawOutput = fields.rawOutput
    exitCode = fields.exitCode
    diffStats = fields.diffStats
    parentToolCallId = fields.parentToolCallId
    detailResource = fields.detailResource
    meta = fields.meta
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: ToolCallKeys.self)
    try container.encode(toolCallId, forKey: .toolCallId)
    try ToolCallFields.encode(
      ToolCallFields(
        title: title, kind: kind, status: status, content: content, locations: locations,
        rawInput: rawInput, rawOutput: rawOutput, exitCode: exitCode, diffStats: diffStats,
        parentToolCallId: parentToolCallId, detailResource: detailResource, meta: meta
      ),
      to: &container
    )
  }

  /// Builds a `ToolCall` from an update, supplying defaults for required fields.
  public func asToolCall() -> ToolCall {
    ToolCall(
      toolCallId: toolCallId,
      title: title ?? "",
      kind: kind,
      status: status,
      content: content,
      locations: locations,
      rawInput: rawInput,
      rawOutput: rawOutput,
      exitCode: exitCode,
      diffStats: diffStats,
      parentToolCallId: parentToolCallId,
      detailResource: detailResource,
      meta: meta
    )
  }
}
