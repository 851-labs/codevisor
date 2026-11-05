import CodevisorNet

extension AppEnvironment {
  public func screenSharingEndpoint() async -> NetEndpointHandle? {
    let tunnel = cloud.directPaths.tunnel
    if localNetworkAccess == .unasked {
      setLocalNetworkAccess(.requested)
      await tunnel.setAllowsDirectPaths(true)
    }
    return await tunnel.screenSharingEndpoint()
  }
}
