/// Coordinates two-phase navigation: the route becomes selected immediately,
/// then expensive destination content commits after the navigation shell has
/// had a chance to paint. Generations reject completions from cancelled taps.
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
