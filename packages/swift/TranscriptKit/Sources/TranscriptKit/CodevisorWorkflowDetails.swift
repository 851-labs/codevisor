import ACPKit
import Foundation

extension ToolCall {
  /// The text the gateway returned, wherever the harness put it: a plain
  /// string, MCP content blocks, or an MCP result object.
  var gatewayOutputText: String? {
    func texts(_ value: JSONValue?) -> [String] {
      guard let value else { return [] }
      if let text = value.stringValue { return [text] }
      if let items = value.arrayValue { return items.flatMap { texts($0) } }
      if let text = value["text"]?.stringValue { return [text] }
      if let content = value["content"] { return texts(content) }
      return []
    }
    if let first = texts(rawOutput).first { return first }
    for block in content ?? [] {
      if case let .content(.text(text, _)) = block { return text }
    }
    return nil
  }

  /// What a gateway `skills` call read: the skill's instructions, or the
  /// list of skills. Nil for every other tool, or before the read returns.
  public var skillText: String? {
    guard codevisorGatewayOperation == .skills,
      let text = gatewayOutputText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return text
  }
}

/// What an expanded gateway workflow shows: the files it produced and what
/// it returned, or why it failed.
public struct CodevisorWorkflowDetails: Equatable, Sendable {
  /// Files the workflow produced (screenshots, recordings), each once.
  public var files: [PreviewFile]
  /// Why the whole workflow failed, when it did.
  public var failure: String?
  /// What the workflow returned: text as-is, anything else as formatted
  /// JSON. JSON the script stringified is unpacked, and file references
  /// (already shown as attachments) are left out.
  public var result: String?
}

extension ToolCall {
  /// Readable details for a gateway `execute` call; nil for every other tool.
  public var codevisorWorkflowDetails: CodevisorWorkflowDetails? {
    guard codevisorGatewayOperation == .execute else { return nil }
    let output = Self.workflowOutput(gatewayOutputText)
    let failed = status == .failed || codevisorExecution?.state == .failed
    var seenFiles = Set<String>()
    return CodevisorWorkflowDetails(
      files: (codevisorExecution?.calls ?? []).flatMap(\.files).filter { seenFiles.insert($0.id).inserted },
      failure: failed
        ? (codevisorExecution?.error ?? output.unparsed).flatMap(ToolCall.shortError) ?? "The workflow failed"
        : nil,
      result: failed ? nil : output.result ?? output.unparsed
    )
  }

  private static func workflowOutput(_ text: String?) -> (result: String?, unparsed: String?) {
    guard let text, !text.isEmpty else { return (nil, nil) }
    guard
      let data = text.data(using: .utf8),
      let wrapper = try? JSONDecoder().decode(JSONValue.self, from: data),
      case let .object(fields) = wrapper,
      fields.keys.contains("result") || fields.keys.contains("logs")
    else { return (nil, text) }
    return (fields["result"].flatMap { cleaned($0, depth: 0) }.flatMap(Self.readable), nil)
  }

  /// `value` as a reader wants it: JSON the script stringified is parsed,
  /// file references are dropped, and a lone `value` wrapper is unwrapped.
  static func cleaned(_ value: JSONValue, depth: Int) -> JSONValue? {
    guard depth < 8 else { return value }
    switch value {
    case .null:
      return nil
    case let .string(text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
      else { return value }
      return cleaned(parsed, depth: depth + 1)
    case let .array(items):
      return .array(items.compactMap { cleaned($0, depth: depth + 1) })
    case let .object(object):
      if object["fileId"]?.stringValue != nil { return nil }
      var kept: [String: JSONValue] = [:]
      for (key, child) in object {
        guard let child = cleaned(child, depth: depth + 1) else { continue }
        if key == "artifacts", child.arrayValue?.isEmpty == true { continue }
        kept[key] = child
      }
      if kept.count == 1, let only = kept["value"] { return only }
      return kept.isEmpty ? nil : .object(kept)
    default:
      return value
    }
  }

  private static func readable(_ value: JSONValue) -> String? {
    if case let .string(text) = value { return text }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
  }
}
