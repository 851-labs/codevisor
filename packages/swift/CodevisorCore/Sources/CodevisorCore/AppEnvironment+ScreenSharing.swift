import CodevisorNet

extension AppEnvironment {
  public func screenSharingEndpoint(requestingLocalNetwork: Bool) async -> NetEndpointHandle? {
    let tunnel = cloud.directPaths.tunnel
    if requestingLocalNetwork, localNetworkAccess == .unasked {
      setLocalNetworkAccess(.requested)
      await tunnel.setAllowsDirectPaths(true)
    }
    return await tunnel.screenSharingEndpoint()
  }
}
