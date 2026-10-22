public struct GitHost: Equatable, Sendable {
  public let name: String
  public let provider: GitHostProvider?

  public init(name: String) {
    self.name = name.lowercased()
    provider = GitHostProvider(host: name)
  }

  public var displayName: String { provider?.displayName ?? name }
  public var logo: SheetSymbol { provider?.logo ?? GitHostProvider.genericLogo }
}
