import Foundation

enum ToolCallKeys: String, CodingKey {
  case toolCallId, title, kind, status, content, locations, rawInput, rawOutput, exitCode, diffStats
  case parentToolCallId, detailResource, isSnapshot, stateRevision, statePosition, chatItemId
  case meta = "_meta"
}

/// Shared lenient field decoding for `ToolCall` and `ToolCallUpdate`: an
/// unknown status string becomes nil, and unrecognized content elements are
/// skipped per-element — a newer server must never make the client drop the
/// whole event.
struct ToolCallFields {
  init(
    title: String?, kind: ToolKind?, status: ToolCallStatus?, content: [ToolCallContent]?,
    locations: [ToolCallLocation]?, rawInput: JSONValue?, rawOutput: JSONValue?, exitCode: Int?,
    diffStats: [ToolCallDiffStat]?, parentToolCallId: String?, detailResource: ToolDetailResource?,
    meta: JSONValue?
  ) {
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

  var title: String?
  var kind: ToolKind?
  var status: ToolCallStatus?
  var content: [ToolCallContent]?
  var locations: [ToolCallLocation]?
  var rawInput: JSONValue?
  var rawOutput: JSONValue?
  var exitCode: Int?
  var diffStats: [ToolCallDiffStat]?
  var parentToolCallId: String?
  var detailResource: ToolDetailResource?
  var meta: JSONValue?

  init(from container: KeyedDecodingContainer<ToolCallKeys>) {
    title = Self.lenient(String.self, from: container, forKey: .title)
    kind = Self.lenient(ToolKind.self, from: container, forKey: .kind)
    // Status and content affect turn liveness (a lost terminal status
    // leaves the call spinning forever), so their swallows log at .error.
    status = Self.decodeStatus(from: container)
    content = Self.decodeContent(from: container)
    locations = Self.lenient([ToolCallLocation].self, from: container, forKey: .locations)
    rawInput = Self.lenient(JSONValue.self, from: container, forKey: .rawInput)
    rawOutput = Self.lenient(JSONValue.self, from: container, forKey: .rawOutput)
    exitCode = Self.lenient(Int.self, from: container, forKey: .exitCode)
    diffStats = Self.lenient([ToolCallDiffStat].self, from: container, forKey: .diffStats)
    parentToolCallId = Self.lenient(String.self, from: container, forKey: .parentToolCallId)
    detailResource = Self.lenient(ToolDetailResource.self, from: container, forKey: .detailResource)
    meta = Self.lenient(JSONValue.self, from: container, forKey: .meta)
  }

  static func encode(
    _ fields: ToolCallFields,
    to container: inout KeyedEncodingContainer<ToolCallKeys>
  ) throws {
    try container.encodeIfPresent(fields.title, forKey: .title)
    try container.encodeIfPresent(fields.kind, forKey: .kind)
    try container.encodeIfPresent(fields.status, forKey: .status)
    try container.encodeIfPresent(fields.content, forKey: .content)
    try container.encodeIfPresent(fields.locations, forKey: .locations)
    try container.encodeIfPresent(fields.rawInput, forKey: .rawInput)
    try container.encodeIfPresent(fields.rawOutput, forKey: .rawOutput)
    try container.encodeIfPresent(fields.exitCode, forKey: .exitCode)
    try container.encodeIfPresent(fields.diffStats, forKey: .diffStats)
    try container.encodeIfPresent(fields.parentToolCallId, forKey: .parentToolCallId)
    try container.encodeIfPresent(fields.detailResource, forKey: .detailResource)
    try container.encodeIfPresent(fields.meta, forKey: .meta)
  }

  private static func decodeStatus(
    from container: KeyedDecodingContainer<ToolCallKeys>
  ) -> ToolCallStatus? {
    do {
      if let raw = try container.decodeIfPresent(String.self, forKey: .status) {
        let status = ToolCallStatus(rawValue: raw)
        if status == nil {
          acpLog.error(
            "Unknown tool call status \"\(raw, privacy: .public)\" — treating as absent"
          )
        }
        return status
      }
    } catch {
      acpLog.error(
        "Tool call status failed to decode: \(String(describing: error), privacy: .public)"
      )
    }
    return nil
  }

  private static func decodeContent(
    from container: KeyedDecodingContainer<ToolCallKeys>
  ) -> [ToolCallContent]? {
    do {
      if let elements = try container.decodeIfPresent(
        [LenientlyDecoded<ToolCallContent>].self, forKey: .content)
      {
        return elements.compactMap(\.value)
      }
    } catch {
      acpLog.error(
        "Tool call content failed to decode: \(String(describing: error), privacy: .public)"
      )
    }
    return nil
  }

  // Decodes an optional field, logging (rather than silently dropping) a
  // value that was present but malformed. Absent keys stay silent.
  private static func lenient<T: Decodable>(
    _ type: T.Type,
    from container: KeyedDecodingContainer<ToolCallKeys>,
    forKey key: ToolCallKeys
  ) -> T? {
    do {
      return try container.decodeIfPresent(T.self, forKey: key)
    } catch {
      acpLog.debug(
        "Tool call \(key.stringValue, privacy: .public) failed to decode: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }
}
