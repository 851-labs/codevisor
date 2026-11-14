import CodevisorClient
import CodevisorNet

extension AppEnvironment {
  public func screenSharingSigner() throws -> ScreenSharingStartSigner {
    try cloud.directPaths.tunnel.screenSharingSigner()
  }

  public func screenSharingEndpoint(requestingLocalNetwork: Bool) async -> NetEndpointHandle? {
    let tunnel = cloud.directPaths.tunnel
    if requestingLocalNetwork, localNetworkAccess == .unasked {
      setLocalNetworkAccess(.requested)
      await tunnel.setAllowsDirectPaths(true)
    }
    return await tunnel.screenSharingEndpoint()
  }
}
