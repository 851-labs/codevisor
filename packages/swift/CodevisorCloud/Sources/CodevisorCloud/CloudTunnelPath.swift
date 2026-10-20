public struct CloudTunnelPath: Equatable, Sendable {
  public var route: CloudTunnelRoute
  public var roundTripMilliseconds: Int

  public init(route: CloudTunnelRoute, roundTripMilliseconds: Int) {
    self.route = route
    self.roundTripMilliseconds = roundTripMilliseconds
  }
}
