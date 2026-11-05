import Testing

@testable import CodevisorCore

@MainActor
struct NetworkPathMonitorTests {
  @Test("Going offline and back reports each change once, and only a regained or switched path asks for recovery")
  func reportsOnlineChangesAndRecoveries() {
    let monitor = NetworkPathMonitor()
    var changes: [Bool] = []
    monitor.onOnlineChange = { changes.append($0) }

    monitor.apply(NetworkPathReading(isSatisfied: true, signature: "satisfied:wifi"))
    monitor.apply(NetworkPathReading(isSatisfied: false, signature: "unsatisfied"))
    monitor.apply(NetworkPathReading(isSatisfied: true, signature: "satisfied:cellular"))
    monitor.apply(NetworkPathReading(isSatisfied: true, signature: "satisfied:cellular"))
    monitor.apply(NetworkPathReading(isSatisfied: true, signature: "satisfied:wifi"))

    #expect(changes == [false, true])
    #expect(monitor.isOnline)
    #expect(monitor.recoveryToken == 2)
  }
}
