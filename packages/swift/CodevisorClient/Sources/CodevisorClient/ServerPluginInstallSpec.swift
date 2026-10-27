import Foundation

public struct ServerPluginInstallSpec: Codable, Equatable, Sendable {
  public var kind: String
  public var fields: [ServerConfigField]

  public init(kind: String, fields: [ServerConfigField] = []) {
    self.kind = kind
    self.fields = fields
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    fields = try container.decodeIfPresent([ServerConfigField].self, forKey: .fields) ?? []
  }
}
