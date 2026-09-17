import CodevisorCore
import SwiftUI

/// Installation work belongs to the machine carrying it out.
public struct HarnessSyncSection: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var isRetrying = false
  @State private var errorMessage: String?
  private let machineId: String

  public init(machineId: String) { self.machineId = machineId }

  private var pending: [HarnessFleet.MachineReadiness] {
    guard let key = environment.machines.syncKey(forMachineId: machineId) else { return [] }
    return HarnessFleet.pendingChanges(environment.configSync, machineKey: key)
  }

  public var body: some View {
    Group {
      if !pending.isEmpty || errorMessage != nil {
        Section("Sync") {
          ForEach(pending) { row in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(setting(for: row)?.name ?? row.harnessId)
                Text(detail(for: row))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Spacer()
              if isInProgress(row) {
                ProgressView().controlSize(.small)
              } else if row.state == "blocked" {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
              }
            }
          }
          if let errorMessage {
            Text(errorMessage).foregroundStyle(.secondary)
          }
          if pending.contains(where: { !isInProgress($0) }) || errorMessage != nil {
            Button("Retry") { Task { await retry() } }
              .disabled(isRetrying)
          }
        }
      }
    }
    .onChange(of: pending) { _, rows in
      if rows.isEmpty { errorMessage = nil }
    }
  }

  private func setting(for row: HarnessFleet.MachineReadiness) -> HarnessFleet.Setting? {
    HarnessFleet.settings(environment.configSync, includingUninstalled: true).first { $0.id == row.harnessId }
  }

  private func isInProgress(_ row: HarnessFleet.MachineReadiness) -> Bool {
    row.state == "installing" || row.state == "uninstalling"
  }

  private func detail(for row: HarnessFleet.MachineReadiness) -> String {
    switch row.state {
    case "installing": return "Installing…"
    case "uninstalling": return "Uninstalling…"
    case "blocked": return row.reason ?? "Couldn’t sync this harness."
    default:
      return setting(for: row)?.installed == false ? "Waiting to uninstall" : "Waiting to install"
    }
  }

  private func retry() async {
    isRetrying = true
    errorMessage = nil
    defer { isRetrying = false }
    do {
      _ = try await environment.machines.client(for: machineId).reconcileHarnessesSync()
      environment.harnessCatalogDidChange(onServer: machineId)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
