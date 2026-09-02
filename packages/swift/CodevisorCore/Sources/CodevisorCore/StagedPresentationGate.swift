/// Coordinates two-phase presentation: a destination is requested immediately
/// while the last committed destination remains visible, then the incoming
/// surface commits after it reports readiness. Generations reject late
/// acknowledgements from superseded requests.
public struct StagedPresentationGate<Route: Hashable> {
  public private(set) var requestedRoute: Route?
  public private(set) var presentedRoute: Route?
  public private(set) var generation: UInt64 = 0

  public init() {}

  @discardableResult
  public mutating func request(_ route: Route) -> UInt64 {
    generation &+= 1
    requestedRoute = route
    return generation
  }

  @discardableResult
  public mutating func commit(_ route: Route, generation: UInt64) -> Bool {
    guard self.generation == generation, requestedRoute == route else { return false }
    presentedRoute = route
    return true
  }
}
