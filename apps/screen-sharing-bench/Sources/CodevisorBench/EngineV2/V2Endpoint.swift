import CodevisorNet

enum V2Endpoint {
  static let defaultPathPolicy = "direct-only"

  static func bind(pathPolicy: String = defaultPathPolicy) async throws -> NetEndpointHandle {
    try await netBindEndpoint(
      config: NetEndpointConfig(
        secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: pathPolicy,
        alpns: [mediaAlpn()]))
  }
}
