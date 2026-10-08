import Foundation

/// The lifecycle status of a tool call. Terminal states are `completed`,
/// `failed`, and `cancelled`.
public enum ToolCallStatus: String, Sendable, Codable, Equatable {
  case pending
  case inProgress = "in_progress"
  case completed
  case failed
  case cancelled
}

/// A categorization of the kind of operation a tool performs.
public enum ToolKind: String, Sendable, Codable, Equatable {
  case read
  case edit
  case delete
  case move
  case search
  case execute
  case think
  case fetch
  case switchMode = "switch_mode"
  /// A web search. Not part of the ACP kind vocabulary — Codevisor's own
  /// extension so clients can phrase these as searches ("Searched the
  /// web") instead of generic fetches.
  case webSearch = "web_search"
  case imageGeneration = "image_generation"
  /// A subagent spawn (e.g. Claude's Task tool). Not part of the ACP kind
  /// vocabulary — Codevisor's own extension so clients can render a nested
  /// transcript section for the call.
  case agent
  /// A question the agent asked the user (AskUserQuestion). Not part of the
  /// ACP kind vocabulary — Codevisor synthesizes an answered question into the
  /// transcript as a tool call so it renders as a normal worked-for row.
  case question
  case other

  /// Decodes leniently so unknown kinds map to `.other`.
  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ToolKind(rawValue: raw) ?? .other
  }
}

/// A file location referenced by a tool call.
public struct ToolCallLocation: Sendable, Codable, Equatable {
  public var path: String
  public var line: UInt32?

  public init(path: String, line: UInt32? = nil) {
    self.path = path
    self.line = line
  }
}

/// Added/removed line counts for one file touched by a tool call. Values are
/// cumulative for the tool call; each update replaces the previous stats.
public struct ToolCallDiffStat: Sendable, Codable, Equatable {
  public var path: String
  public var added: Int
  public var removed: Int

  public init(path: String, added: Int, removed: Int) {
    self.path = path
    self.added = added
    self.removed = removed
  }
}

/// A value that swallows its own decoding failures, so one unrecognized
/// element can be skipped instead of failing the containing decode (which
/// would drop the whole session update on the floor).
public struct LenientlyDecoded<Wrapped: Decodable>: Decodable {
  public let value: Wrapped?

  public init(from decoder: any Decoder) {
    do {
      value = try Wrapped(from: decoder)
    } catch {
      value = nil
      acpLog.error(
        "Skipped malformed \(String(describing: Wrapped.self), privacy: .public) element: \(String(describing: error), privacy: .public)"
      )
    }
  }
}

/// Content produced by a tool call. Discriminated by `type`.
public enum ToolCallContent: Sendable, Codable, Equatable {
  case content(ContentBlock)
  case diff(path: String, oldText: String?, newText: String)
  case terminal(terminalId: String)

  private enum Keys: String, CodingKey {
    case type, content, path, oldText, newText, terminalId
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "content":
      self = .content(try container.decode(ContentBlock.self, forKey: .content))
    case "diff":
      self = .diff(
        path: try container.decode(String.self, forKey: .path),
        oldText: try container.decodeIfPresent(String.self, forKey: .oldText),
        newText: try container.decode(String.self, forKey: .newText)
      )
    case "terminal":
      self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown tool call content type: \(type)"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case let .content(block):
      try container.encode("content", forKey: .type)
      try container.encode(block, forKey: .content)
    case let .diff(path, oldText, newText):
      try container.encode("diff", forKey: .type)
      try container.encode(path, forKey: .path)
      try container.encodeIfPresent(oldText, forKey: .oldText)
      try container.encode(newText, forKey: .newText)
    case let .terminal(terminalId):
      try container.encode("terminal", forKey: .type)
      try container.encode(terminalId, forKey: .terminalId)
    }
  }
}

public struct ToolDetailResource: Codable, Equatable, Sendable {
  public struct Field: Codable, Equatable, Sendable {
    public var name: String
    public var revision: Int
    public var encoding: String
    public var sizeBytes: Int
    public var pageCount: Int? = nil
    public var generation: Int? = nil
  }
  public var itemId: String
  public var entryKey: String
  public var fields: [Field]
}

/// A complete tool call as first reported via a `tool_call` session update.
public struct ToolCall: Sendable, Codable, Equatable, Identifiable {
  public var isSnapshot: Bool? = nil
  public var stateRevision: Int? = nil
  public var statePosition: Int? = nil
  public var chatItemId: String? = nil
  public var toolCallId: String
  public var title: String
  public var kind: ToolKind?
  public var status: ToolCallStatus?
  public var content: [ToolCallContent]?
  public var locations: [ToolCallLocation]?
  public var rawInput: JSONValue?
  public var rawOutput: JSONValue?
  /// Numeric process exit status, when the harness reports one.
  public var exitCode: Int?
  /// Cumulative added/removed line counts per file, streamed while the edit
  /// is being generated by providers that can observe it.
  public var diffStats: [ToolCallDiffStat]?
  /// When set, this call was made by a subagent spawned by the tool call
  /// with that id (e.g. a Claude Task) — clients nest it under the parent.
  public var parentToolCallId: String?
  public var detailResource: ToolDetailResource?
  /// The ACP `_meta` extension object. Codevisor attaches gateway execution
  /// state here (`_meta.codevisorExecution`).
  public var meta: JSONValue?

  public var id: String { toolCallId }

  public init(
    toolCallId: String,
    title: String,
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
    isSnapshot = try container.decodeIfPresent(Bool.self, forKey: .isSnapshot)
    stateRevision = try container.decodeIfPresent(Int.self, forKey: .stateRevision)
    statePosition = try container.decodeIfPresent(Int.self, forKey: .statePosition)
    chatItemId = try container.decodeIfPresent(String.self, forKey: .chatItemId)
    let fields = ToolCallFields(from: container)
    title = fields.title ?? ""
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
    try container.encodeIfPresent(isSnapshot, forKey: .isSnapshot)
    try container.encodeIfPresent(stateRevision, forKey: .stateRevision)
    try container.encodeIfPresent(statePosition, forKey: .statePosition)
    try container.encodeIfPresent(chatItemId, forKey: .chatItemId)
    try ToolCallFields.encode(
      ToolCallFields(
        title: title, kind: kind, status: status, content: content, locations: locations,
        rawInput: rawInput, rawOutput: rawOutput, exitCode: exitCode, diffStats: diffStats,
        parentToolCallId: parentToolCallId, detailResource: detailResource, meta: meta
      ),
      to: &container
    )
  }

  /// Applies a `ToolCallUpdate`, returning a new merged tool call. Only fields
  /// present in the update overwrite existing values.
  public func applying(_ update: ToolCallUpdate) -> ToolCall {
    var result = self
    if let title = update.title { result.title = title }
    if let kind = update.kind { result.kind = kind }
    if let status = update.status { result.status = status }
    if let content = update.content { result.content = content }
    if let locations = update.locations { result.locations = locations }
    if let rawInput = update.rawInput { result.rawInput = rawInput }
    if let rawOutput = update.rawOutput { result.rawOutput = rawOutput }
    if let exitCode = update.exitCode { result.exitCode = exitCode }
    if let diffStats = update.diffStats { result.diffStats = diffStats }
    if let parentToolCallId = update.parentToolCallId { result.parentToolCallId = parentToolCallId }
    if let resource = update.detailResource { result.detailResource = resource }
    if let meta = update.meta { result.meta = meta }
    return result
  }

  /// True once the call has reached a terminal status.
  public var isSettled: Bool {
    status == .completed || status == .failed || status == .cancelled
  }
}
