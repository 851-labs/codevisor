public struct CloudEphemeralOrigin: Codable, Equatable, Sendable {
  public var provider: String
  public var ownerDeviceId: String

  public init(provider: String, ownerDeviceId: String) {
    self.provider = provider
    self.ownerDeviceId = ownerDeviceId
  }

  public var label: String {
    "Ephemeral · \(providerName)"
  }

  public var providerName: String {
    switch provider {
    case "e2b": "E2B"
    case "modal": "Modal"
    case "tart": "Tart"
    default: provider
    }
  }
}
