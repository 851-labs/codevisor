import ACPKit
import Foundation

/// What an expanded gateway workflow shows: the code it ran, plus the
/// failure or result as a fallback when a harness didn't report the code.
public struct CodevisorWorkflowDetails: Equatable, Sendable {
  public var code: String?
  /// Why the whole workflow failed, when it did.
  public var failure: String?
  /// The script's return value: text as-is, anything else as formatted JSON.
  public var result: String?
}

extension ToolCall {
  /// Readable details for a gateway `execute` call; nil for every other tool.
  public var codevisorWorkflowDetails: CodevisorWorkflowDetails? {
    guard codevisorGatewayOperation == .execute else { return nil }
    let output = Self.workflowOutput(outputText)
    let failed = status == .failed || codevisorExecution?.state == .failed
    return CodevisorWorkflowDetails(
      code: rawInput?["code"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
      failure: failed
        ? (codevisorExecution?.error ?? output.unparsed).flatMap(ToolCall.shortError) ?? "The workflow failed"
        : nil,
      result: failed ? nil : output.result ?? output.unparsed
    )
  }

  /// The text the gateway returned, wherever the harness put it: a plain
  /// string, MCP content blocks, or an MCP result object.
  private var outputText: String? {
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

  private static func workflowOutput(_ text: String?) -> (result: String?, unparsed: String?) {
    guard let text, !text.isEmpty else { return (nil, nil) }
    guard
      let data = text.data(using: .utf8),
      let wrapper = try? JSONDecoder().decode(JSONValue.self, from: data),
      case let .object(fields) = wrapper,
      fields.keys.contains("result") || fields.keys.contains("logs")
    else { return (nil, text) }
    return (fields["result"].flatMap(Self.readable), nil)
  }

  private static func readable(_ value: JSONValue) -> String? {
    switch value {
    case .null: return nil
    case let .string(text): return text
    default:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
  }
}
