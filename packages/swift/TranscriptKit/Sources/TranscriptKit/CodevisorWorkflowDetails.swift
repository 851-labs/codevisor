import ACPKit
import Foundation

extension ToolCall {
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

  public var skillText: String? {
    guard codevisorGatewayOperation == .skills,
      let text = gatewayOutputText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return text
  }
}

public struct CodevisorWorkflowDetails: Equatable, Sendable {
  public var files: [PreviewFile]
  public var failure: String?
  public var result: String?
}

extension ToolCall {
  public var codevisorWorkflowDetails: CodevisorWorkflowDetails? {
    guard codevisorGatewayOperation == .execute else { return nil }
    let output = Self.workflowOutput(gatewayOutputText)
    let failed = status == .failed || codevisorExecution?.state == .failed
    var seenFiles = Set<String>()
    return CodevisorWorkflowDetails(
      files: (codevisorExecution?.calls ?? []).flatMap(\.files).filter { seenFiles.insert($0.id).inserted },
      failure: failed
        ? (codevisorExecution?.error ?? output.unparsed).flatMap(Self.errorDetail) ?? "The workflow failed"
        : nil,
      result: failed ? nil : output.result ?? output.unparsed
    )
  }

  static func errorDetail(_ error: String) -> String? {
    let text = error.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.range(of: #"^\s*at\s"#, options: .regularExpression) == nil }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
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
