import Foundation

public struct ServerPluginAccountDraft: Encodable, Equatable, Sendable {
  public var id: String?
  public var label: String?
  public var values: [String: ServerConfigFieldValue]

  public init(id: String? = nil, label: String? = nil, values: [String: ServerConfigFieldValue] = [:]) {
    self.id = id
    self.label = label
    self.values = values
  }
}
