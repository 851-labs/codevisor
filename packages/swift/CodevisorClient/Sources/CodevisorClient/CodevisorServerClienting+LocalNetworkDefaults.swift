extension CodevisorServerClienting {
  public func setCloudDirectPaths(_: Bool) async throws {}

  public func cloudLocalNetworkPermission() async throws -> LocalNetworkPermission {
    throw CodevisorServerClientError.invalidResponse
  }
}
