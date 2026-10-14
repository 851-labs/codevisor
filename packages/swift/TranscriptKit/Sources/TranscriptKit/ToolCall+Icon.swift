import ACPKit
import Foundation

public struct ToolCallIcon: Equatable, Hashable, Sendable {
  public enum Artwork: Equatable, Hashable, Sendable {
    case site(origin: String)
    case mcpServer(id: String, host: String?)
    case app(bundleId: String, path: String?)
  }

  public var symbol: String
  public var artwork: Artwork?

  public static let codevisorMark = "codevisor.mark"

  public init(symbol: String, artwork: Artwork? = nil) {
    self.symbol = symbol
    self.artwork = artwork
  }
}

public enum CodevisorExecutionIconRef: Equatable, Sendable {
  case site(origin: String)
  case mcp(serverId: String, host: String?)
  case app(bundleId: String, path: String?)
  case builtin(String)

  init?(json: JSONValue?) {
    guard let json, let kind = json["kind"]?.stringValue else { return nil }
    switch kind {
    case "site":
      guard let origin = json["origin"]?.stringValue, !origin.isEmpty else { return nil }
      self = .site(origin: origin)
    case "mcp":
      guard let id = json["serverId"]?.stringValue, !id.isEmpty else { return nil }
      self = .mcp(serverId: id, host: json["host"]?.stringValue)
    case "app":
      guard let bundleId = json["bundleId"]?.stringValue, !bundleId.isEmpty else { return nil }
      self = .app(bundleId: bundleId, path: json["path"]?.stringValue)
    case "builtin":
      guard let id = json["id"]?.stringValue else { return nil }
      self = .builtin(id)
    default:
      return nil
    }
  }

  var icon: ToolCallIcon {
    switch self {
    case let .site(origin):
      return ToolCallIcon(symbol: "globe", artwork: .site(origin: origin))
    case let .mcp(serverId, host):
      return ToolCallIcon(symbol: ToolCall.mcpServerSymbol, artwork: .mcpServer(id: serverId, host: host))
    case let .app(bundleId, path):
      return ToolCallIcon(symbol: "display", artwork: .app(bundleId: bundleId, path: path))
    case .builtin("browser"): return ToolCallIcon(symbol: "globe")
    case .builtin("computer"): return ToolCallIcon(symbol: "display")
    case .builtin("codevisor"): return ToolCallIcon(symbol: ToolCallIcon.codevisorMark)
    case .builtin: return ToolCallIcon(symbol: ToolCall.integrationSymbol)
    }
  }
}

extension ToolCall {
  static let integrationSymbol = "puzzlepiece.extension"
  static let mcpServerSymbol = "point.3.connected.trianglepath.dotted"

  public var icon: ToolCallIcon {
    if isToolDiscoveryCall { return ToolCallIcon(symbol: "magnifyingglass") }
    switch codevisorGatewayOperation {
    case .skills:
      return ToolCallIcon(symbol: "book")
    case .execute:
      let execution = codevisorExecution
      let ref = isSettled ? execution?.icon ?? execution?.activeIcon : execution?.activeIcon ?? execution?.icon
      return ref?.icon ?? ToolCallIcon(symbol: Self.integrationSymbol)
    case nil:
      return ToolCallIcon(symbol: ToolCallSummary.symbol([self]))
    }
  }
}
