import Foundation
import ACPKit

/// Semantic presentation for Codevisor's tool gateway. Each harness spells MCP
/// names differently (`codevisor.execute`, `mcp__codevisor__execute`, or
/// `codevisor_execute`), but the transcript should describe the user's action,
/// not the adapter's wire format.
public enum CodevisorGatewayOperation: String {
  case execute
}

extension ToolCall {
  public var codevisorGatewayOperation: CodevisorGatewayOperation? {
    let normalized =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    let prefixes = [
      "mcp__codevisor__", "codevisor.", "codevisor_",
      // Persisted transcripts keep their original wire-level tool names.
      "mcp__herdman__", "herdman.", "herdman_",
    ]
    let operation = prefixes.first(where: normalized.hasPrefix).map {
      String(normalized.dropFirst($0.count))
    }
    return operation.flatMap(CodevisorGatewayOperation.init(rawValue:))
  }

  /// Codex's built-in tool discovery is part of the same integration flow
  /// when it appears beside Codevisor calls, and deserves a readable label.
  public var isToolDiscoveryCall: Bool {
    let normalized =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
    return normalized == "toolsearch"
  }

  public var isIntegrationPresentationCall: Bool {
    codevisorGatewayOperation != nil || isToolDiscoveryCall
  }

  public func integrationDisplayTitle() -> String? {
    if isToolDiscoveryCall {
      return isSettled ? "Searched available tools" : "Searching available tools…"
    }
    guard let operation = codevisorGatewayOperation else { return nil }
    switch operation {
    case .execute:
      guard let description = integrationDescription else {
        return isSettled ? "Ran an integration workflow" : "Running an integration workflow…"
      }
      // One line: a running workflow shows its latest status() in place of
      // its description, then settles back to the description.
      if let liveStatus = integrationLiveStatus { return liveStatus }
      guard status == .failed || codevisorExecution?.state == .failed else { return description }
      guard let error = codevisorExecution?.error.flatMap(Self.shortError) else {
        return "\(description) — failed"
      }
      return "\(description) — failed: \(error)"
    }
  }

  /// The model's own label for a gateway workflow (`execute`'s required
  /// `description` argument), when the harness reported it. Only the first
  /// line is used, capped at the label length the tool asks the model for.
  public var integrationDescription: String? {
    guard codevisorGatewayOperation == .execute,
      let firstLine = rawInput?["description"]?.stringValue?
        .split(whereSeparator: \.isNewline).first
    else { return nil }
    let description = firstLine.trimmingCharacters(in: .whitespaces)
    guard !description.isEmpty else { return nil }
    let limit = 80
    guard description.count > limit else { return description }
    return String(description.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Live gateway state the server attaches to an `execute` row.
  public var codevisorExecution: CodevisorExecution? {
    guard codevisorGatewayOperation == .execute else { return nil }
    return meta?["codevisorExecution"].flatMap(CodevisorExecution.init(json:))
  }

  /// The latest `status()` text of a workflow that is still running.
  var integrationLiveStatus: String? {
    guard !isSettled, codevisorExecution?.state != .failed,
      let status = codevisorExecution?.status?.trimmingCharacters(in: .whitespacesAndNewlines),
      !status.isEmpty
    else { return nil }
    return status
  }

  /// The message a person needs from an error: its first line, without an
  /// "Error:" prefix or appended stack frames.
  static func shortError(_ error: String) -> String? {
    var line =
      error
      .split(whereSeparator: \.isNewline)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    while let prefix = line.range(of: #"^[A-Za-z]*Error:\s*"#, options: .regularExpression) {
      line.removeSubrange(prefix)
    }
    if let frames = line.range(of: #"\s+at\s+(<anonymous>|file:|node:|[\w$.]+\s*\().*$"#, options: .regularExpression) {
      line.removeSubrange(frames)
    }
    line = line.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return nil }
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
  }
}

/// The gateway's record of one `execute` run (`_meta.codevisorExecution`).
public struct CodevisorExecution: Equatable, Sendable {
  public enum State: String, Sendable {
    case running, completed, failed
  }

  public struct Call: Equatable, Sendable {
    public var path: String
    /// The machine the call was routed to, when it was not local.
    public var machine: String?
    public var ok: Bool
  }

  public var state: State?
  public var status: String?
  public var calls: [Call]
  public var error: String?

  init?(json: JSONValue) {
    guard case .object = json else { return nil }
    state = json["state"]?.stringValue.flatMap(State.init(rawValue:))
    status = json["status"]?.stringValue
    error = json["error"]?.stringValue
    calls = (json["calls"]?.arrayValue ?? []).compactMap { call in
      guard let path = call["path"]?.stringValue else { return nil }
      return Call(
        path: path,
        machine: call["machine"]?.stringValue,
        ok: call["ok"]?.boolValue ?? true
      )
    }
  }
}
