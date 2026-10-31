import CodevisorNet

enum V2Endpoint {
  static func bind() async throws -> NetEndpointHandle {
    try await netBindEndpoint(
      config: NetEndpointConfig(
        secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: "direct-only",
        alpns: [mediaAlpn()]))
  }
}
