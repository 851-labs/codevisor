import Foundation

public struct ServerPluginCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var description: String
  public var publisher: String
  public var version: String
  public var transport: String
  public var url: String?
  public var iconUrl: String?
  public var docsUrl: String?
  public var capabilities: ServerPluginCapabilities
  public var source: String?
  public var install: ServerPluginInstallSpec?
  public var accounts: ServerPluginAccountSpec?

  public init(
    id: String,
    name: String,
    description: String,
    publisher: String,
    version: String,
    transport: String,
    url: String? = nil,
    iconUrl: String? = nil,
    docsUrl: String? = nil,
    capabilities: ServerPluginCapabilities = .init(),
    source: String? = nil,
    install: ServerPluginInstallSpec? = nil,
    accounts: ServerPluginAccountSpec? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.publisher = publisher
    self.version = version
    self.transport = transport
    self.url = url
    self.iconUrl = iconUrl
    self.docsUrl = docsUrl
    self.capabilities = capabilities
    self.source = source
    self.install = install
    self.accounts = accounts
  }

  public var installFields: [ServerConfigField] { install?.fields ?? [] }
}
