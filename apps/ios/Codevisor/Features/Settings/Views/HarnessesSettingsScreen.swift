import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Harnesses

/// Harness management starts with machines, then separates installed
/// harnesses from the catalog available on each machine.
struct HarnessesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var refreshToken = UUID()
  @State private var isRefreshing = false

  var body: some View {
    List {
      let machines = environment.machines.allMachines
      if machines.count == 1, let machine = machines.first {
        HarnessMachineSections(
          machine: machine,
          refreshToken: refreshToken,
          isRefreshing: $isRefreshing
        )
      } else {
        Section {
          ForEach(machines) { machine in
            NavigationLink {
              HarnessMachineSettingsScreen(machine: machine)
            } label: {
              HStack {
                Text(machine.name)
                Spacer(minLength: 12)
                badge(machine).view
                  .font(.footnote)
              }
            }
          }
        }
      }
    }
    .navigationTitle("Harnesses")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if environment.machines.allMachines.count == 1 {
          HarnessRefreshButton(isRefreshing: $isRefreshing) {
            refreshToken = UUID()
          }
        }
      }
    }
  }

  private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
    if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
      return .attention("Unreachable")
    }
    guard let key = environment.machines.syncKey(forMachineId: machine.id),
      let rows = HarnessFleet.readiness(environment.configSync)[key]
    else { return .syncing }
    if rows.contains(where: { $0.state == "signInRequired" }) {
      return .attention("Sign in required")
    }
    return .synced
  }
}

/// The contextual manager used by the model picker. Installation stays in
/// this navigation stack and retains the sheet's compact detent.
struct HarnessMachineSettingsScreen: View {
  let machine: CodevisorMachine
  @State private var refreshToken = UUID()
  @State private var isRefreshing = false

  var body: some View {
    List {
      HarnessMachineSections(
        machine: machine,
        refreshToken: refreshToken,
        isRefreshing: $isRefreshing
      )
    }
    .navigationTitle("Harnesses")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        HarnessRefreshButton(isRefreshing: $isRefreshing) {
          refreshToken = UUID()
        }
      }
    }
  }
}

/// Keeps the native toolbar button in place while its refresh is running.
private struct HarnessRefreshButton: View {
  @Binding var isRefreshing: Bool
  let refresh: () -> Void

  var body: some View {
    Button {
      guard !isRefreshing else { return }
      isRefreshing = true
      refresh()
    } label: {
      ZStack {
        Image(systemName: "arrow.clockwise")
          .opacity(isRefreshing ? 0 : 1)
        if isRefreshing {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .disabled(isRefreshing)
    .accessibilityLabel(isRefreshing ? "Refreshing Harnesses" : "Refresh Harnesses")
  }
}

/// Separate native list sections keep installed harnesses and the install
/// catalog visually and behaviorally distinct.
private struct HarnessMachineSections: View {
  @Environment(AppEnvironment.self) private var environment
  let machine: CodevisorMachine
  let refreshToken: UUID
  @Binding var isRefreshing: Bool

  @State private var harnesses: [ServerHarness] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var showsAvailableToInstall = true

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machine.id)
  }

  private var installed: [ServerHarness] {
    harnesses.filter(\.isReady)
  }

  private var notInstalled: [ServerHarness] {
    harnesses.filter { !$0.isReady }
  }

  var body: some View {
    Group {
      if isLoading, harnesses.isEmpty {
        Section {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
        }
      } else if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("Try Again") { Task { await load(rescan: true) } }
        }
      } else {
        if !installed.isEmpty {
          Section("Installed") {
            ForEach(installed, id: \.id) { harness in
              installedHarnessRow(harness)
            }
          }
        }

        if !notInstalled.isEmpty {
          Section {
            DisclosureGroup(isExpanded: $showsAvailableToInstall) {
              ForEach(notInstalled, id: \.id) { harness in
                availableHarnessRow(harness)
              }
            } label: {
              HStack {
                Text("Available to Install")
                Spacer()
                Text(notInstalled.count, format: .number)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .task(id: "\(machine.id):\(refreshToken)") {
      isLoading = true
      await load(rescan: true)
      if !Task.isCancelled {
        isRefreshing = false
      }
    }
    .onChange(of: environment.harnessCatalogRevision(for: machine.id)) { _, _ in
      Task { await load() }
    }
  }

  private func installedHarnessRow(_ harness: ServerHarness) -> some View {
    NavigationLink {
      HarnessDetailScreen(machine: machine, harness: harness) { updated in
        updateHarness(updated)
      }
    } label: {
      harnessLabel(harness)
    }
  }

  @ViewBuilder
  private func availableHarnessRow(_ harness: ServerHarness) -> some View {
    if harness.lifecycle?.resolvedPhase == .installing {
      HStack(spacing: 12) {
        harnessLabel(harness)
        Spacer()
        ProgressView()
          .controlSize(.small)
      }
    } else {
      NavigationLink {
        HarnessInstallScreen(harness: harness, machine: machine) { started, methodId in
          noteInstallStarted(started, harness: harness, methodId: methodId)
        }
      } label: {
        harnessLabel(harness)
      }
    }
  }

  private func harnessLabel(_ harness: ServerHarness) -> some View {
    HStack(spacing: 12) {
      HarnessIconView(
        harnessId: harness.id,
        fallbackSymbolName: harness.symbolName,
        size: 22
      )
      Text(harness.name)
    }
    .padding(.vertical, 2)
  }

  private func noteInstallStarted(
    _ started: ServerHarnessOperationStarted,
    harness: ServerHarness,
    methodId: String
  ) {
    let lifecycle =
      started.lifecycle
      ?? ServerHarnessLifecycleState(
        phase: "installing",
        methodId: methodId,
        terminalId: started.terminalId
      )
    if let index = harnesses.firstIndex(where: { $0.id == harness.id }) {
      harnesses[index].lifecycle = lifecycle
    }
    environment.setHarnessLifecycle(
      lifecycle,
      harnessId: harness.id,
      onServer: machine.id
    )
    environment.harnessCatalogDidChange(onServer: machine.id)
  }

  private func updateHarness(_ harness: ServerHarness) {
    if let index = harnesses.firstIndex(where: { $0.id == harness.id }) {
      harnesses[index] = harness
    }
  }

  private func load(rescan: Bool = false) async {
    do {
      let loaded =
        try await
        (rescan
        ? client.rescanHarnesses()
        : client.listHarnessesWithLifecycle())
      guard !Task.isCancelled else { return }
      harnesses = loaded
      errorMessage = nil
      isLoading = false
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      isLoading = false
    }
  }
}

/// Installed-harness controls live on their own detail page instead of
/// competing for space and meaning in the list row.
private struct HarnessDetailScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let machine: CodevisorMachine
  let onChanged: (ServerHarness) -> Void

  @State private var harness: ServerHarness
  @State private var isChangingEnabled = false
  @State private var errorMessage: String?
  @State private var showsAuthentication = false

  init(
    machine: CodevisorMachine,
    harness: ServerHarness,
    onChanged: @escaping (ServerHarness) -> Void
  ) {
    self.machine = machine
    self.onChanged = onChanged
    _harness = State(initialValue: harness)
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machine.id)
  }

  var body: some View {
    Form {
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { harness.isDesiredEnabled },
            set: { enabled in Task { await setEnabled(enabled) } }
          )
        )
        .disabled(isChangingEnabled)
      }

      if let auth = harness.auth, auth.resolvedState != .notRequired {
        Section {
          Button {
            showsAuthentication = true
          } label: {
            HStack {
              Label(
                auth.isSatisfied ? "Manage Accounts" : "Sign In",
                systemImage: "person.crop.circle"
              )
              Spacer()
              if auth.resolvedState == .checking {
                ProgressView()
                  .controlSize(.small)
              }
            }
          }
          .disabled(auth.resolvedState == .checking)
        }
      }
    }
    .navigationTitle(harness.name)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showsAuthentication) {
      HarnessAuthenticationScreen(
        serverId: machine.id,
        harness: harness,
        onAuthenticated: {
          showsAuthentication = false
          Task { await load() }
        }
      )
      .navigationTitle(harness.name)
      .navigationBarTitleDisplayMode(.inline)
      .onDisappear { Task { await load() } }
    }
    .task(id: "\(machine.id):\(harness.id)") { await load() }
  }

  private func setEnabled(_ enabled: Bool) async {
    isChangingEnabled = true
    defer { isChangingEnabled = false }
    do {
      harness = try await client.setHarnessDesiredEnabled(id: harness.id, enabled: enabled)
      errorMessage = nil
      onChanged(harness)
      environment.harnessCatalogDidChange(onServer: machine.id)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func load() async {
    do {
      guard
        let refreshed = try await client.listHarnessesWithLifecycle()
          .first(where: { $0.id == harness.id })
      else { return }
      harness = refreshed
      errorMessage = nil
      onChanged(refreshed)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
