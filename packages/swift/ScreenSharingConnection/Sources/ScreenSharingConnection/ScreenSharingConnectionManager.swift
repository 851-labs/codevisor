@MainActor
public final class ScreenSharingConnectionManager {
  private struct Key: Hashable {
    let machineId: String
    let target: String?
  }

  private let clock: ScreenSharingConnectionClock
  private var connections: [Key: ScreenSharingConnection] = [:]

  public init(clock: ScreenSharingConnectionClock = .live) {
    self.clock = clock
  }

  public func connection(for machine: ScreenSharingMachine) -> ScreenSharingConnection {
    let key = Key(machineId: machine.id, target: machine.target)
    if let existing = connections[key] { return existing }

    let connection = ScreenSharingConnection(machine: machine, clock: clock)
    connections[key] = connection
    return connection
  }

  public func machineCameOnline(_ machineId: String) {
    for connection in connections(of: machineId) { connection.machineCameOnline() }
  }

  public func targetAppeared(_ machineId: String, target: String) {
    connections[Key(machineId: machineId, target: target)]?.targetAppeared()
  }

  public func systemWoke() {
    for connection in connections.values { connection.systemWoke() }
  }

  public func remove(_ machineId: String) {
    for key in connections.keys where key.machineId == machineId { connections.removeValue(forKey: key)?.end() }
  }

  public func remove(_ machineId: String, target: String) {
    connections.removeValue(forKey: Key(machineId: machineId, target: target))?.end()
  }

  public func shutdown() {
    for connection in connections.values { connection.end() }
    connections.removeAll()
  }

  private func connections(of machineId: String) -> [ScreenSharingConnection] {
    connections.filter { $0.key.machineId == machineId }.map(\.value)
  }
}
