import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Harnesses

/// Shared desired settings, with machine overrides beneath.
struct HarnessesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var globalModel = HarnessGlobalModel()
  @State private var accountsSetting: HarnessFleet.Setting?

  var body: some View {
    List {
      HarnessGlobalSection(model: globalModel, onAccounts: { accountsSetting = $0 }) { id, symbol in
        HarnessIconView(harnessId: id, fallbackSymbolName: symbol, size: 22)
      }
      Section("Machines") {
        ForEach(environment.machines.allMachines) { machine in
          NavigationLink {
            HarnessMachineSettingsScreen(machine: machine)
          } label: {
            HStack {
              Text(machine.name)
              Spacer(minLength: 12)
              badge(machine).view.font(.footnote)
            }
          }
        }
      }
    }
    .navigationTitle("Harnesses")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $accountsSetting) { setting in
      HarnessAccountsSheet(harnessId: setting.id, harnessName: setting.name) { machineId, harness, request in
        HarnessAuthenticationScreen(serverId: machineId ?? "", harness: harness, signInRequest: request)
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        HarnessAddButton(model: globalModel) { id, symbol in
          HarnessIconView(harnessId: id, fallbackSymbolName: symbol, size: 22)
        }
        .labelStyle(.iconOnly)
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
    if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
    if !HarnessFleet.pendingChanges(environment.configSync, machineKey: key).isEmpty { return .syncing }
    let count = HarnessFleet.overrideCount(environment.configSync, machineKey: key)
    if count > 0 { return .overrides(count) }
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
      HarnessSyncSection(machineId: machine.id)
      HarnessMachineSections(
        machine: machine,
        refreshToken: refreshToken,
        isRefreshing: $isRefreshing
      )
    }
    .navigationTitle(machine.name)
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
      VStack(alignment: .leading, spacing: 8) {
        NavigationLink {
          HarnessInstallScreen(harness: harness, machine: machine) { started, methodId in
            noteInstallStarted(started, harness: harness, methodId: methodId)
          }
        } label: {
          harnessLabel(harness)
        }
        if harness.hasOverride {
          Button("Use Global Setting") {
            Task {
              do {
                updateHarness(try await client.resetHarnessOverride(id: harness.id))
                environment.harnessCatalogDidChange(onServer: machine.id)
              } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
            }
          }
          .font(.callout)
        }
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
      VStack(alignment: .leading, spacing: 3) {
        Text(harness.name)
        Text(harness.lifecycle?.resolvedPhase == .uninstalling ? "Uninstalling…" : harness.settingsSummary)
          .font(.caption).foregroundStyle(.secondary)
      }
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
  @State private var confirmsUninstall = false
  @State private var confirmsReset = false

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
        .disabled(isChangingEnabled || harness.isLifecycleBusy)
        if harness.hasOverride {
          Button("Use Global Setting") {
            if harness.settings?.global?.installed == false && harness.isReady {
              confirmsReset = true
            } else {
              Task { await resetOverride() }
            }
          }
          .disabled(isChangingEnabled || harness.isLifecycleBusy)
        }
      } footer: {
        Text(harness.settingsSummary)
      }

      if let auth = harness.auth, auth.resolvedState != .notRequired {
        Section {
          Button {
            showsAuthentication = true
          } label: {
            HStack {
              Label(
                "Accounts",
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
      Section {
        if harness.lifecycle?.resolvedPhase == .uninstalling {
          HStack {
            Text("Uninstalling…")
            Spacer()
            ProgressView()
          }
        } else if harness.isReady {
          Button("Uninstall…", role: .destructive) { confirmsUninstall = true }
            .disabled(isChangingEnabled || harness.isLifecycleBusy)
        } else {
          Text("Not installed").foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle(harness.name)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showsAuthentication, onDismiss: { Task { await load() } }) {
      HarnessSignInSheet(
        request: HarnessSignInRequest(serverId: machine.id, harnessId: harness.id, initialHarness: harness)
      )
    }
    .task(id: "\(machine.id):\(harness.id)") { await load() }
    .onChange(of: environment.harnessCatalogRevision(for: machine.id)) { _, _ in Task { await load() } }
    .alert("Uninstall \(harness.name)?", isPresented: $confirmsUninstall) {
      Button("Uninstall", role: .destructive) { Task { await uninstall() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes the CLI from \(machine.name). Chats and accounts are kept.")
    }
    .alert("Use Global Setting?", isPresented: $confirmsReset) {
      Button("Uninstall", role: .destructive) { Task { await resetOverride() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The global setting will uninstall \(harness.name) here.")
    }
  }

  private func resetOverride() async {
    isChangingEnabled = true
    defer { isChangingEnabled = false }
    do {
      harness = try await client.resetHarnessOverride(id: harness.id)
      errorMessage = nil
      onChanged(harness)
      environment.harnessCatalogDidChange(onServer: machine.id)
    } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
  }

  private func uninstall() async {
    isChangingEnabled = true
    defer { isChangingEnabled = false }
    do {
      let started = try await client.uninstallHarness(id: harness.id)
      harness.lifecycle = started.lifecycle
      errorMessage = nil
      onChanged(harness)
      if let lifecycle = started.lifecycle {
        environment.setHarnessLifecycle(lifecycle, harnessId: harness.id, onServer: machine.id)
      }
      environment.harnessCatalogDidChange(onServer: machine.id)
    } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
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
