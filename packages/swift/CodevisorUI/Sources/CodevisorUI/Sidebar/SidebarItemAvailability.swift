public enum SidebarItemAvailability: Hashable, Sendable {
  case available
  case pending
  case gone

  public enum Listing: Hashable, Sendable {
    case listed
    case hidden
    case missing
  }

  public enum Machine: Hashable, Sendable {
    case unknown
    case connecting
    case reachable
    case unreachable
  }

  public init(_ listing: Listing, on machine: Machine) {
    switch (listing, machine) {
    case (_, .unknown), (_, .unreachable), (.hidden, _): self = .gone
    case (.listed, _): self = .available
    case (.missing, .connecting): self = .pending
    case (.missing, .reachable): self = .gone
    }
  }
}
