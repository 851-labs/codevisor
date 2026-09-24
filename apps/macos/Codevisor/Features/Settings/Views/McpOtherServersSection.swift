import CodevisorCore
import CodevisorUI
import SwiftUI

/// MCP servers that live in a machine's own harness config files, plus the
/// ones Codevisor offers to adopt. These stay machine-major on purpose:
/// they describe files on one disk, and folding them into fleet entries
/// would claim a reach they do not have. Collapsed by default, grouped by
/// machine, so the fleet list above stays the page's subject.
struct McpOtherServersSection: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Binding var isExpanded: Bool
  @State private var scans: [String: ServerNativeMcpScan] = [:]
  @State private var expandedMachines: Set<String> = []
  @State private var importing: Set<String> = []
  @State private var feedback: String?
  @State private var selectedServer: ServerNativeMcpServer?
  @State private var pendingRemoval: NativeRemovalRequest?
  @State private var lastRemoval: NativeRemovalRecord?

  /// A removal has to name the machine as well as the server: the same
  /// harness config exists on every machine, and only one of them is meant.
  private struct NativeRemovalRequest: Identifiable {
    let machineId: String
    let server: ServerNativeMcpServer
    var id: String { "\(machineId)|\(server.id)" }
  }

  private struct NativeRemovalRecord: Identifiable {
    let machineId: String
    let machineName: String
    let removal: ServerNativeMcpRemoval
    var id: String { removal.id }
  }

  private var total: Int {
    scans.values.reduce(0) { sum, scan in
      sum + scan.harnesses.reduce(0) { $0 + $1.servers.count } + scan.candidates.filter { !$0.alreadyManaged }.count
    }
  }

  var body: some View {
    Group {
      if total > 0 {
        Section {
          SettingsDisclosureRow(
            "Other MCP servers on your machines (\(total))", isExpanded: $isExpanded
          ) {
            ForEach(machinesWithScans, id: \.id) { machine in
              machineGroup(machine)
                .padding(.leading, 17)
                .padding(.top, 6)
            }
            if let feedback {
              Text(feedback)
                .font(.callout).foregroundStyle(.secondary)
                .padding(.leading, 17).padding(.top, 6)
            } else if let record = lastRemoval {
              HStack(spacing: 8) {
                Text("Removed \(record.removal.serverName).")
                  .font(.callout).foregroundStyle(.secondary)
                Button("Undo") { Task { await undoRemoval(record) } }
                  .buttonStyle(.borderless)
                  .settingsActionTint(theme)
                  .controlSize(.small)
              }
              .padding(.leading, 17).padding(.top, 6)
            }
          }
        }
      }
    }
    .task(id: environment.machines.allMachines.map(\.id)) { await reload() }
    .sheet(item: $selectedServer) { server in
      NativeMcpDetailSheet(server: server)
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.server.serverName ?? "server") from "
        + "\(pendingRemoval?.server.harnessName ?? "harness")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove from \(pendingRemoval?.server.harnessName ?? "Harness")", role: .destructive) {
        guard let request = pendingRemoval else { return }
        Task { await removeNative(request) }
      }
      .settingsActionTint(theme)
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
        .settingsActionTint(theme)
    }
  }

  private func machineName(_ machineId: String?) -> String {
    environment.machines.allMachines.first { $0.id == machineId }?.name ?? "that machine"
  }

  /// Codevisor edits a harness's own config file only on explicit request:
  /// one-time backup, surgical excision, and the fragment parked for undo.
  private func removeNative(_ request: NativeRemovalRequest) async {
    pendingRemoval = nil
    do {
      let result = try await environment.machines.client(for: request.machineId)
        .removeNativeMcp(
          harnessId: request.server.harnessId, serverName: request.server.serverName)
      scans[request.machineId] = result.scan
      lastRemoval = NativeRemovalRecord(
        machineId: request.machineId, machineName: machineName(request.machineId),
        removal: result.removal)
      feedback = nil
    } catch {
      feedback = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func undoRemoval(_ record: NativeRemovalRecord) async {
    do {
      scans[record.machineId] = try await environment.machines.client(for: record.machineId)
        .restoreNativeMcpRemoval(id: record.removal.id)
      lastRemoval = nil
      feedback = nil
    } catch {
      feedback = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private var machinesWithScans: [CodevisorMachine] {
    environment.machines.allMachines.filter { machine in
      guard let scan = scans[machine.id] else { return false }
      return !scan.harnesses.allSatisfy(\.servers.isEmpty)
        || scan.candidates.contains { !$0.alreadyManaged }
    }
  }

  @ViewBuilder
  private func machineGroup(_ machine: CodevisorMachine) -> some View {
    let scan = scans[machine.id] ?? .init()
    let candidates = scan.candidates.filter { !$0.alreadyManaged }
    SettingsDisclosureRow(isExpanded: expansion(machine.id)) {
      Image(systemName: "desktopcomputer").frame(width: 16)
      Text(machine.name)
        .foregroundStyle(theme.isSystem ? Color.primary : theme.textPrimary)
    } content: {
      ForEach(candidates) { candidate in
        McpImportCandidateRow(
          candidate: candidate,
          foundIn: harnessNames(scan: scan, ids: candidate.foundIn),
          isImporting: importing.contains(candidate.identity),
          importDisabled: !importing.isEmpty,
          onImport: { Task { await importCandidate(machine.id, candidate.identity) } }
        )
        .padding(.leading, 23).padding(.top, 6)
      }
      ForEach(scan.harnesses.filter { !$0.servers.isEmpty }) { harness in
        ForEach(harness.servers) { server in
          NativeMcpServerRow(
            server: server,
            setEnabled: { enabled in
              await setNativeEnabled(machine.id, server: server, enabled: enabled)
            },
            showDetails: { selectedServer = server },
            requestRemoval: {
              pendingRemoval = NativeRemovalRequest(machineId: machine.id, server: server)
            }
          )
          .padding(.leading, 23).padding(.top, 6)
        }
      }
    }
  }

  private func expansion(_ machineId: String) -> Binding<Bool> {
    Binding(
      get: { expandedMachines.contains(machineId) },
      set: { expanded in
        if expanded {
          expandedMachines.insert(machineId)
        } else {
          expandedMachines.remove(machineId)
        }
      })
  }

  private func harnessNames(scan: ServerNativeMcpScan, ids: [String]) -> String {
    let names = scan.harnesses.reduce(into: [String: String]()) { partial, harness in
      partial[harness.harnessId] = harness.harnessName
    }
    return ids.map { names[$0] ?? $0 }.joined(separator: ", ")
  }

  /// Native discovery is best-effort: an older server or a scan failure
  /// simply contributes nothing instead of failing the page.
  private func reload() async {
    var found: [String: ServerNativeMcpScan] = [:]
    for machine in environment.machines.allMachines {
      guard let scan = try? await environment.machines.client(for: machine.id).listNativeMcps()
      else { continue }
      found[machine.id] = scan
    }
    guard !Task.isCancelled else { return }
    scans = found
  }

  private func importCandidate(_ machineId: String, _ identity: String) async {
    importing.insert(identity)
    defer { importing.remove(identity) }
    do {
      let result = try await environment.machines.client(for: machineId)
        .importNativeMcps(identities: [identity])
      scans[machineId] = result.scan
      feedback = result.outcomes.compactMap { $0.detail }.first
    } catch {
      feedback = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func setNativeEnabled(
    _ machineId: String, server: ServerNativeMcpServer, enabled: Bool
  ) async {
    do {
      scans[machineId] = try await environment.machines.client(for: machineId)
        .setNativeMcpEnabled(
          harnessId: server.harnessId, serverName: server.serverName, enabled: enabled)
      feedback = nil
    } catch {
      feedback = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
