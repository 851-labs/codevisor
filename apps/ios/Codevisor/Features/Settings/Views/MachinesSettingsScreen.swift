import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Machines

/// Machine management: the paired remote machines (never the on-device
/// "local" pseudo-machine — this client has no local server), as a flat
/// list — rename and removal live on the rows. There is no per-machine page
/// and no selection affordance: the fleet is always connected, and which
/// machine the app points at follows the chat you open.
struct MachinesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var isAddingMachine = false
  @State private var isAddingDevelopmentMachine = false
  @State private var developmentError: String?
  @State private var discovery = TailnetMachineDiscovery()
  @State private var discoveredTarget: TailnetMachineDiscovery.Discovered?
  @State private var renamingMachine: CodevisorMachine?
  @State private var renameText = ""

  let focusedMachineID: String?

  private var machines: MachineController { environment.machines }

  init(focusedMachineID: String? = nil) {
    self.focusedMachineID = focusedMachineID
  }

  private var remoteMachines: [CodevisorMachine] {
    machines.allMachines.filter { !$0.isLocal }
  }

  var body: some View {
    ScrollViewReader { proxy in
      List {
        Section {
          ForEach(remoteMachines, id: \.id) { machine in
            Group {
              if machine.id == focusedMachineID {
                machineRow(machine)
                  .listRowBackground(Color.accentColor.opacity(0.12))
              } else {
                machineRow(machine)
              }
            }
            .id(machine.id)
          }
        } footer: {
          InlineCodeText("Run `codevisor setup` on a machine to print its address and token.")
        }
        if !discovery.discovered.isEmpty {
          Section {
            ForEach(discovery.discovered) { machine in
              discoveredRow(machine)
            }
          } header: {
            Text("On Your Tailnet")
          } footer: {
            Text("Codevisor servers found on your tailnet. Adding one still needs its connection token.")
          }
        }
        Section {
          Button {
            isAddingMachine = true
          } label: {
            Label("Add Machine…", systemImage: "plus")
          }
        }
        if let devRemote = CodevisorAppVariant.developmentRemote,
          developmentMachine(devRemote) == nil
        {
          developmentSection(devRemote)
        }
      }
      .task(id: focusedMachineID) {
        guard let focusedMachineID else { return }
        await Task.yield()
        withAnimation(.snappy(duration: 0.3)) {
          proxy.scrollTo(focusedMachineID, anchor: .center)
        }
      }
    }
    .navigationTitle("Machines")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $isAddingMachine) {
      AddMachineSheet()
    }
    .alert("Rename Machine", isPresented: renamePresented, presenting: renamingMachine) { machine in
      TextField("Name", text: $renameText)
      Button("Rename") {
        try? machines.renameMachine(machine.id, to: renameText)
        renamingMachine = nil
      }
      Button("Cancel", role: .cancel) { renamingMachine = nil }
    }
    .sheet(item: $discoveredTarget) { machine in
      AddMachineSheet(initialHost: machine.host, initialName: machine.name)
    }
    // Discover only while this screen is on screen — no background polling.
    .task {
      while !Task.isCancelled {
        await discovery.refresh(machines: machines)
        try? await Task.sleep(for: .seconds(30))
      }
    }
    // A removed machine may be discoverable again (and a just-added one
    // must leave the list) — refresh whenever the machine list changes.
    .onChange(of: machines.machines.map(\.id)) { _, _ in
      Task { await discovery.refresh(machines: machines) }
    }
  }

  private var renamePresented: Binding<Bool> {
    Binding(
      get: { renamingMachine != nil },
      set: { if !$0 { renamingMachine = nil } }
    )
  }

  private func connectionError(for machine: CodevisorMachine) -> String? {
    if case let .stale(message) = machines.navigationSyncStateByMachineId[machine.id] {
      return message
    }
    if case let .failed(message) = machines.availabilityByMachineId[machine.id] {
      return message
    }
    if let status = machines.statusByMachineId[machine.id], !status.isReachable {
      return status.label
    }
    return nil
  }

  private func isConnecting(to machine: CodevisorMachine) -> Bool {
    if case .waiting = machines.availabilityByMachineId[machine.id] {
      return true
    }
    return machines.navigationSyncStateByMachineId[machine.id] == .catchingUp
  }

  /// Keep the name and connection state on one line. The last error stays
  /// available to VoiceOver while a trailing spinner shows an active retry.
  private func machineRow(_ machine: CodevisorMachine) -> some View {
    let error = connectionError(for: machine)
    return HStack(spacing: 10) {
      if error != nil {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
      } else {
        Image(systemName: EntitySystemSymbol.machine(machine))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Text(machine.name)
      Spacer(minLength: 10)
      if isConnecting(to: machine) {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Connecting")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(error ?? "")
    .contentShape(Rectangle())
    .contextMenu {
      Button("Rename…") {
        renameText = machine.name
        renamingMachine = machine
      }
      Button("Remove Machine…", role: .destructive) {
        try? machines.removeMachine(machine.id)
      }
    }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        try? machines.removeMachine(machine.id)
      } label: {
        Label("Remove", systemImage: "trash")
      }
      Button {
        renameText = machine.name
        renamingMachine = machine
      } label: {
        Label("Rename", systemImage: "pencil")
      }
    }
  }

  private func discoveredRow(_ machine: TailnetMachineDiscovery.Discovered) -> some View {
    Button {
      discoveredTarget = machine
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "desktopcomputer")
          .foregroundStyle(.secondary)
        Text(machine.name)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "plus.circle.fill")
          .foregroundStyle(.tint)
      }
    }
  }

  /// Dev-only shortcut, as on macOS: one tap adds the dev remote that
  /// `bun run dev:ios` started, no token entry. Hidden once it's paired —
  /// remove it like any other machine from its row.
  private func developmentSection(_ remote: CodevisorAppVariant.DevelopmentRemote) -> some View {
    Section {
      Button {
        Task { await addDevelopmentMachine(remote) }
      } label: {
        Label("Add \(remote.name)", systemImage: "bolt.fill")
      }
      .disabled(isAddingDevelopmentMachine)
    } header: {
      Text("Development")
    } footer: {
      if let developmentError {
        Text(developmentError)
          .foregroundStyle(.red)
      } else {
        Text("\(remote.name) at \(remote.hostWithPort), started by bun run dev:ios.")
      }
    }
  }

  /// The registered machine matching the dev remote (by host + port), if
  /// it has been added — the section hides itself once paired.
  private func developmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) -> CodevisorMachine? {
    machines.machines.first { machine in
      machine.baseURL.host() == remote.host
        && (machine.baseURL.port ?? CodevisorAppVariant.productionPort) == remote.port
    }
  }

  private func addDevelopmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) async {
    isAddingDevelopmentMachine = true
    developmentError = nil
    defer { isAddingDevelopmentMachine = false }
    do {
      let added = try await machines.addRemoteValidating(
        host: remote.hostWithPort,
        name: remote.name,
        token: remote.token
      )
      environment.composerDefaults.rememberNewWorkspaceServer(serverId: added.id)
      await environment.prepareMachine(added.id)
    } catch {
      developmentError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
