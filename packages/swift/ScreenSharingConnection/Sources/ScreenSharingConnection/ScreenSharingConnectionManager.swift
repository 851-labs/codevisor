@MainActor
public final class ScreenSharingConnectionManager {
  private let clock: ScreenSharingConnectionClock
  private var connections: [String: ScreenSharingConnection] = [:]

  public init(clock: ScreenSharingConnectionClock = .live) {
    self.clock = clock
  }

  public func connection(for machine: ScreenSharingMachine) -> ScreenSharingConnection {
    if let existing = connections[machine.id] { return existing }

    let connection = ScreenSharingConnection(machine: machine, clock: clock)
    connections[machine.id] = connection
    return connection
  }

  public func machineCameOnline(_ machineId: String) {
    connections[machineId]?.machineCameOnline()
  }

  public func workspaceAppeared(_ machineId: String) {
    connections[machineId]?.workspaceAppeared()
  }

  public func systemWoke() {
    for connection in connections.values { connection.systemWoke() }
  }

  public func remove(_ machineId: String) {
    connections.removeValue(forKey: machineId)?.end()
  }

  public func shutdown() {
    for connection in connections.values { connection.end() }
    connections.removeAll()
  }
}
