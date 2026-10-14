import Foundation
import ACPKit

public enum CodevisorGatewayOperation: String {
  case execute
  case skills
}

extension ToolCall {
  public var codevisorGatewayOperation: CodevisorGatewayOperation? {
    let normalized =
      title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    let prefixes = [
      "mcp__codevisor__", "codevisor__", "codevisor.", "codevisor_",
      "mcp__herdman__", "herdman.", "herdman_",
    ]
    let operation = prefixes.first(where: normalized.hasPrefix).map {
      String(normalized.dropFirst($0.count))
    }
    if let operation = operation.flatMap(CodevisorGatewayOperation.init(rawValue:)) { return operation }
    if normalized == "execute", meta?["codevisorExecution"] != nil { return .execute }
    return meta?["codevisorSkill"] == nil ? nil : .skills
  }

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
      if let liveStatus = integrationLiveStatus { return liveStatus }
      guard status == .failed || codevisorExecution?.state == .failed else { return description }
      guard let error = codevisorExecution?.error.flatMap(Self.shortError) else {
        return "\(description) — failed"
      }
      return "\(description) — failed: \(error)"
    case .skills:
      let failed = status == .failed || meta?["codevisorSkill"]?["ok"]?.boolValue == false
      guard let name = skillName else {
        if failed { return "Couldn’t list skills" }
        return isSettled ? "Listed skills" : "Listing skills…"
      }
      if failed { return "Couldn’t read the \(name) skill" }
      return isSettled ? "Read the \(name) skill" : "Reading the \(name) skill…"
    }
  }

  var skillName: String? {
    guard codevisorGatewayOperation == .skills,
      let name = (rawInput?["name"]?.stringValue ?? meta?["codevisorSkill"]?["name"]?.stringValue)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else { return nil }
    return name
  }

  public var integrationDescription: String? {
    guard codevisorGatewayOperation == .execute,
      let firstLine = (rawInput?["description"]?.stringValue ?? codevisorExecution?.description)?
        .split(whereSeparator: \.isNewline).first
    else { return nil }
    let description = firstLine.trimmingCharacters(in: .whitespaces)
    guard !description.isEmpty else { return nil }
    let limit = 80
    guard description.count > limit else { return description }
    return String(description.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  public var subagentTaskId: String? {
    meta?["codevisorSubagent"]?["taskId"]?.stringValue
  }

  public var continuesSubagent: Bool {
    meta?["codevisorSubagent"]?["continues"]?.boolValue == true
  }

  public var codevisorExecution: CodevisorExecution? {
    guard codevisorGatewayOperation == .execute else { return nil }
    return meta?["codevisorExecution"].flatMap(CodevisorExecution.init(json:))
  }

  var integrationLiveStatus: String? {
    guard !isSettled, codevisorExecution?.state != .failed,
      let status = codevisorExecution?.status?.trimmingCharacters(in: .whitespacesAndNewlines),
      !status.isEmpty
    else { return nil }
    return status
  }

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

public struct CodevisorExecution: Equatable, Sendable {
  public enum State: String, Sendable {
    case running, completed, failed
  }

  public struct Call: Equatable, Sendable {
    public var path: String
    public var machine: String?
    public var ok: Bool
    public var files: [PreviewFile]
  }

  public var state: State?
  public var description: String?
  public var status: String?
  public var calls: [Call]
  public var error: String?
  public var icon: CodevisorExecutionIconRef?
  public var activeIcon: CodevisorExecutionIconRef?

  private static func file(_ json: JSONValue) -> PreviewFile? {
    guard let fileId = json["fileId"]?.stringValue, !fileId.isEmpty else { return nil }
    let mimeType = json["mimeType"]?.stringValue ?? "application/octet-stream"
    return PreviewFile(
      source: .attachment(fileId: fileId),
      name: json["name"]?.stringValue ?? "File",
      mimeType: mimeType,
      kind: mimeType.hasPrefix("image/") ? .image : .file
    )
  }

  init?(json: JSONValue) {
    guard case .object = json else { return nil }
    icon = CodevisorExecutionIconRef(json: json["icon"])
    activeIcon = CodevisorExecutionIconRef(json: json["activeIcon"])
    state = json["state"]?.stringValue.flatMap(State.init(rawValue:))
    description = json["description"]?.stringValue
    status = json["status"]?.stringValue
    error = json["error"]?.stringValue
    calls = (json["calls"]?.arrayValue ?? []).compactMap { call in
      guard let path = call["path"]?.stringValue else { return nil }
      return Call(
        path: path,
        machine: call["machine"]?.stringValue,
        ok: call["ok"]?.boolValue ?? true,
        files: (call["files"]?.arrayValue ?? []).compactMap(Self.file)
      )
    }
  }
}
