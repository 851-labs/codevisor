import Foundation

public struct McpFleetSummary: Equatable, Sendable {
  public let entry: McpFleetEntry
  public let rows: [McpFleet.MachineRow]

  public init(entry: McpFleetEntry, rows: [McpFleet.MachineRow]) {
    self.entry = entry
    self.rows = rows
  }

  public var needsSignIn: Bool {
    usesOAuth && liveRows.contains { $0.status.needsAuthorization }
  }

  public var isSignedIn: Bool {
    usesOAuth && !needsSignIn && liveRows.contains(where: \.isReady)
  }

  public var label: String {
    if needsSignIn { return "Needs sign-in" }
    if let attention = liveRows.first(where: \.status.rowStatus.needsAttention) {
      return attention.status.label
    }
    if let busy = liveRows.first(where: \.status.rowStatus.isBusy) { return busy.status.label }
    if liveRows.isEmpty { return "Off" }
    if liveRows.count < reachableRows.count {
      return "On \(liveRows.count) of \(reachableRows.count) machines"
    }
    return readyLabel
  }

  private var usesOAuth: Bool { entry.authType == "oauth" }

  private var reachableRows: [McpFleet.MachineRow] {
    rows.filter { $0.status != .unreachable }
  }

  private var liveRows: [McpFleet.MachineRow] {
    reachableRows.filter(\.isOn)
  }

  private var readyLabel: String {
    entry.isBuiltIn ? "On" : "Connected"
  }
}

private extension McpFleet.MachineRow {
  var isReady: Bool {
    if case .ready = status { true } else { false }
  }
}
