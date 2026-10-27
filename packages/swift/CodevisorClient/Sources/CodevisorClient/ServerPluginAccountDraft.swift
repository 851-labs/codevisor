import Foundation

public struct ServerPluginAccountDraft: Encodable, Equatable, Sendable {
  public var label: String?
  public var values: [String: ServerConfigFieldValue]

  public init(label: String? = nil, values: [String: ServerConfigFieldValue] = [:]) {
    self.label = label
    self.values = values
  }
}
