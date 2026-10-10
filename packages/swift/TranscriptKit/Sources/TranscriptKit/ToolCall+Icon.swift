import ACPKit
import Foundation

/// What a transcript row draws beside a tool call: an SF Symbol, optionally
/// replaced by artwork the server resolves — the favicon of a site a browser
/// workflow visited, or the icon of the MCP server a workflow called. The
/// symbol is always set, so a row never waits on (or loses) its icon.
public struct ToolCallIcon: Equatable, Hashable, Sendable {
  public enum Artwork: Equatable, Hashable, Sendable {
    /// A site's favicon, by origin (`https://linear.app`).
    case site(origin: String)
    /// An MCP server's icon. `host` resolves servers this machine lacks.
    case mcpServer(id: String, host: String?)
  }

  public var symbol: String
  public var artwork: Artwork?

  public init(symbol: String, artwork: Artwork? = nil) {
    self.symbol = symbol
    self.artwork = artwork
  }
}

/// What a gateway workflow touched (`_meta.codevisorExecution.icon` and
/// `.activeIcon`), as the gateway reports it.
public enum CodevisorExecutionIconRef: Equatable, Sendable {
  case site(origin: String)
  case mcp(serverId: String, host: String?)
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
    case .builtin("browser"): return ToolCallIcon(symbol: "globe")
    case .builtin("computer"): return ToolCallIcon(symbol: "display")
    case .builtin: return ToolCallIcon(symbol: ToolCall.integrationSymbol)
    }
  }
}

extension ToolCall {
  static let integrationSymbol = "puzzlepiece.extension"
  /// The symbol Settings uses for MCP servers without artwork.
  static let mcpServerSymbol = "point.3.connected.trianglepath.dotted"

  /// This call's own icon. A running workflow shows what it is touching
  /// now; a settled one, the first thing it touched (what it was about).
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
