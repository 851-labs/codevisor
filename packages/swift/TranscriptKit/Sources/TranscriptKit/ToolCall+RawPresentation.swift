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
      // A command alone is worth opening only when it shows more than the
      // title's one line: a script, or a command the title cut short.
      return !(content?.isEmpty ?? true) || rawOutput != nil
        || shellCommand.map { !title.hasSuffix($0) } == true
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

public extension ToolCall {
  /// The full command or script a shell call ran, as a terminal would echo
  /// it. Harnesses report it as `command` (or `cmd`): a string, or an argv
  /// array. A login-shell wrapper (`/bin/zsh -lc '…'`) is unwrapped to the
  /// script it runs.
  var shellCommand: String? {
    guard kind == .execute, let rawInput else { return nil }
    let value = rawInput["command"] ?? rawInput["cmd"]
    let command: String?
    if let text = value?.stringValue {
      command = Self.unwrappingShellInvocation(text)
    } else if let argv = value?.arrayValue?.compactMap(\.stringValue), !argv.isEmpty {
      command = Self.script(fromArgv: argv) ?? argv.joined(separator: " ")
    } else {
      command = nil
    }
    guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
    else { return nil }
    return command
  }

  private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]

  /// `["/bin/bash", "-lc", script]` → `script`.
  private static func script(fromArgv argv: [String]) -> String? {
    guard argv.count == 3,
      shells.contains((argv[0] as NSString).lastPathComponent),
      ["-c", "-lc", "-cl"].contains(argv[1])
    else { return nil }
    return argv[2]
  }

  /// `/bin/zsh -lc 'rg -n "x"'` → `rg -n "x"`; anything else as-is.
  static func unwrappingShellInvocation(_ command: String) -> String {
    let pattern = #"^\s*(?:\S*/)?(sh|bash|zsh|fish|dash)\s+-(?:lc|cl|c)\s+(['"])([\s\S]*)\2\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
      let quoteRange = Range(match.range(at: 2), in: command),
      let bodyRange = Range(match.range(at: 3), in: command)
    else { return command }
    let body = String(command[bodyRange])
    if command[quoteRange] == "'" {
      return decodeSingleQuotedShellBody(body, original: command)
    }
    return decodeDoubleQuotedShellBody(body, original: command)
  }

  private static func decodeSingleQuotedShellBody(_ body: String, original command: String) -> String {
    // A single-quoted shell word can't contain `'`; joiners splice one in
    // as `'\''` or `'"'"'`. Any other bare quote means it isn't one word.
    let splices = [#"'\''"#, #"'"'"'"#]
    let bare = splices.reduce(body) { $0.replacingOccurrences(of: $1, with: "") }
    guard !bare.contains("'") else { return command }
    return splices.reduce(body) { $0.replacingOccurrences(of: $1, with: "'") }
  }

  private static func decodeDoubleQuotedShellBody(_ body: String, original command: String) -> String {
    var result = ""
    var escaping = false
    for character in body {
      if escaping {
        if !["\"", "\\", "$", "`"].contains(character) { result.append("\\") }
        result.append(character)
        escaping = false
      } else if character == "\\" {
        escaping = true
      } else if character == "\"" {
        return command
      } else {
        result.append(character)
      }
    }
    return escaping ? command : result
  }
}
