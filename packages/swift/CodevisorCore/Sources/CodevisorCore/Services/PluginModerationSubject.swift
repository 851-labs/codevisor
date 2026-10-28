import CryptoKit
import Foundation

public struct PluginModerationSubject: Equatable, Hashable, Sendable {
  public let pluginId: String
  public let name: String
  public let publisher: String
  public let declaredAgeRating: Int?
  public let consentKey: String

  public var isCustom: Bool { pluginId.hasPrefix(Self.customPrefix) }

  private static let customPrefix = "custom:"

  public init(pluginId: String, name: String, publisher: String, declaredAgeRating: Int?, revision: String) {
    self.pluginId = pluginId
    self.name = name
    self.publisher = publisher
    self.declaredAgeRating = declaredAgeRating
    self.consentKey = Self.digest("\(pluginId)|\(revision)")
  }

  public init(catalogEntry entry: ServerPluginCatalogEntry) {
    self.init(
      pluginId: entry.id,
      name: entry.name,
      publisher: Self.publisher(ofCatalogId: entry.id),
      declaredAgeRating: entry.ageRating,
      revision: entry.version)
  }

  public init(server: ServerMcpServer) {
    if let catalogId = server.catalogId {
      self.init(
        pluginId: catalogId,
        name: server.name,
        publisher: Self.publisher(ofCatalogId: catalogId),
        declaredAgeRating: server.ageRating,
        revision: server.catalogVersion ?? "")
    } else {
      self.init(custom: CustomPluginLocation(server: server), name: server.name)
    }
  }

  public init(custom location: CustomPluginLocation, name: String) {
    self.init(
      pluginId: Self.customPrefix + location.identity,
      name: name,
      publisher: location.publisher,
      declaredAgeRating: nil,
      revision: location.identity)
  }

  public static func publisher(ofCatalogId id: String) -> String {
    let namespace = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
    return namespace.lowercased()
  }

  private static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct CustomPluginLocation: Equatable, Sendable {
  public let identity: String
  public let publisher: String

  public init(transport: String, url: String?, command: String?, args: [String]) {
    if transport == "http", let host = url.flatMap(URL.init(string:))?.host() {
      identity = host.lowercased()
      publisher = identity
    } else {
      let program = command ?? ""
      identity = ([program] + args).joined(separator: " ")
      publisher = URL(fileURLWithPath: program).lastPathComponent.lowercased()
    }
  }

  init(server: ServerMcpServer) {
    self.init(transport: server.transport, url: server.url, command: server.command, args: server.args)
  }
}
