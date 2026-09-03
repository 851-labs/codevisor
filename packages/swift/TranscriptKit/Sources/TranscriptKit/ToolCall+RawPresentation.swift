import ACPKit
import Foundation

/// A presentation-ready piece of a tool call's provider-native payload.
/// `text` always retains the complete value; `preview` bounds the initial UI
/// cost for command output that can be hundreds of kilobytes or more.
public struct ToolCallRawSection: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case command
    case input
    case output
  }

  public let kind: Kind
  public let text: String
  public let preview: String
  public let isTruncated: Bool

  public var id: Kind { kind }

  public var title: String {
    switch kind {
    case .command: "Command"
    case .input: "Input"
    case .output: "Output"
    }
  }

  fileprivate init(kind: Kind, value: JSONValue, previewCharacterLimit: Int) {
    self.kind = kind
    text = Self.displayText(for: value)
    (preview, isTruncated) = Self.makePreview(text, limit: previewCharacterLimit)
  }

  private static func displayText(for value: JSONValue) -> String {
    if case let .string(text) = value { return text }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard
      let data = try? encoder.encode(value),
      let text = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return text
  }

  private static func makePreview(_ text: String, limit: Int) -> (String, Bool) {
    let boundedLimit = max(8, limit)
    let probe = text.prefix(boundedLimit + 1)
    guard probe.count > boundedLimit else { return (text, false) }

    let headCount = boundedLimit * 3 / 4
    let tailCount = boundedLimit - headCount
    let marker = "\n\n… truncated …\n\n"
    return (String(text.prefix(headCount)) + marker + String(text.suffix(tailCount)), true)
  }
}

public extension ToolCall {
  /// Whether expanding this row can reveal typed content or provider-native
  /// input/output. This check deliberately avoids formatting the raw values so
  /// collapsed transcript rows stay cheap.
  var hasPresentableDetails: Bool {
    if kind == .execute {
      return !(content?.isEmpty ?? true) || rawOutput != nil
    }
    return !(content?.isEmpty ?? true) || rawInput != nil || rawOutput != nil || exitCode != nil
  }

  /// Provider-native output when no richer ACP content is available. Shell
  /// disclosures use this directly so formatting their hidden command input
  /// is not part of rendering a potentially large result.
  func rawOutputDetailSection(previewCharacterLimit: Int = 8_192) -> ToolCallRawSection? {
    guard content?.isEmpty ?? true, let rawOutput else { return nil }
    return ToolCallRawSection(
      kind: .output,
      value: rawOutput,
      previewCharacterLimit: previewCharacterLimit
    )
  }

  /// Provider-native payload sections used when no richer ACP content exists.
  /// Execute inputs are omitted because their command is already summarized in
  /// the tool-call title. Other raw inputs and all raw outputs are fallbacks so
  /// edits and web sources are not duplicated.
  func rawDetailSections(previewCharacterLimit: Int = 8_192) -> [ToolCallRawSection] {
    let hasTypedContent = !(content?.isEmpty ?? true)
    var sections: [ToolCallRawSection] = []

    if let rawInput, kind != .execute, !hasTypedContent {
      sections.append(
        ToolCallRawSection(
          kind: .input,
          value: rawInput,
          previewCharacterLimit: previewCharacterLimit
        ))
    }

    if let rawOutput = rawOutputDetailSection(previewCharacterLimit: previewCharacterLimit) {
      sections.append(rawOutput)
    }
    return sections
  }
}
