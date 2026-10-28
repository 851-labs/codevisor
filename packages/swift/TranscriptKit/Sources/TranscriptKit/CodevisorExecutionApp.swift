import ACPKit
import Foundation

public struct CodevisorExecutionApp: Decodable, Equatable, Hashable, Identifiable, Sendable {
  public var viewId: String
  public var machineId: String?
  public var serverId: String
  public var serverName: String
  public var toolName: String
  public var resourceUri: String

  public var id: String { viewId }

  public init(
    viewId: String,
    machineId: String? = nil,
    serverId: String,
    serverName: String,
    toolName: String,
    resourceUri: String
  ) {
    self.viewId = viewId
    self.machineId = machineId
    self.serverId = serverId
    self.serverName = serverName
    self.toolName = toolName
    self.resourceUri = resourceUri
  }

  init?(json: JSONValue) {
    guard let viewId = Self.nonEmpty(json["viewId"]), let serverId = Self.nonEmpty(json["serverId"]),
      let resourceUri = Self.nonEmpty(json["resourceUri"])
    else { return nil }

    self.init(
      viewId: viewId,
      machineId: Self.nonEmpty(json["machineId"]),
      serverId: serverId,
      serverName: Self.nonEmpty(json["serverName"]) ?? serverId,
      toolName: json["toolName"]?.stringValue ?? "",
      resourceUri: resourceUri
    )
  }

  public func owningMachineId(fallback: String) -> String {
    machineId ?? fallback
  }

  static func decodeList(_ json: JSONValue?) -> [CodevisorExecutionApp] {
    var seen: Set<String> = []
    return (json?.arrayValue ?? []).compactMap(CodevisorExecutionApp.init(json:)).filter {
      seen.insert($0.viewId).inserted
    }
  }

  private static func nonEmpty(_ value: JSONValue?) -> String? {
    guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    return text
  }
}
