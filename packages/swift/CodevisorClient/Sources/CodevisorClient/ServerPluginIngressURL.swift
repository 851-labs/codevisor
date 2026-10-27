import Foundation

public struct ServerPluginIngressURL: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var title: String?
  public var url: String

  public var id: String { name }

  public init(name: String, title: String? = nil, url: String) {
    self.name = name
    self.title = title
    self.url = url
  }
}
