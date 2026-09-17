import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Harnesses

/// Shared desired settings, with machine overrides beneath.
struct HarnessesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var globalModel = HarnessGlobalModel()
  @State private var accountsSetting: HarnessAccountsPresentation<HarnessFleet.Setting>?

  var body: some View {
    List {
      HarnessGlobalSection(
        model: globalModel,
        onAccounts: { setting, signIn in
          accountsSetting = .init(setting, startsSignIn: signIn)
        }
      ) { id, symbol in
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
    .sheet(item: $accountsSetting) { presentation in
      let setting = presentation.selection
      HarnessAccountsSheet(harnessId: setting.id, harnessName: setting.name, startsSignIn: presentation.startsSignIn) {
        machineId, harness, request in
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
  @Environment(AppEnvironment.self) private var environment
  let machine: CodevisorMachine
  @State private var refreshToken = UUID()
  @State private var isRefreshing = false
  @State private var model = HarnessMachineModel()
  @State private var authenticationHarness: HarnessAccountsPresentation<ServerHarness>?
  @State private var uninstallHarness: ServerHarness?
  @State private var resetHarness: ServerHarness?

  var body: some View {
    List {
      HarnessSyncSection(machineId: machine.id)
      HarnessMachineSections(
        machine: machine,
        model: model,
        presentAccounts: { authenticationHarness = .init($0, startsSignIn: $1) },
        requestUninstall: { uninstallHarness = $0 },
        resetOverride: { harness in
          if harness.settings?.global?.installed == false && harness.isReady {
            resetHarness = harness
          } else {
            Task { await model.resetOverride(id: harness.id) }
          }
        }
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
    .sheet(item: $authenticationHarness, onDismiss: { Task { await model.refresh() } }) { presentation in
      let harness = presentation.selection
      HarnessMachineAccountsSheet(machine: machine, harness: harness, startsSignIn: presentation.startsSignIn)
    }
    .alert(
      model.operationError?.title ?? "Couldn't Update Harness",
      isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.dismissOperationError() } })
    ) {
      Button("OK") { model.dismissOperationError() }
    } message: {
      Text(model.operationError?.message ?? "")
    }
    .confirmationDialog(
      "Uninstall \(uninstallHarness?.name ?? "harness")?",
      isPresented: Binding(get: { uninstallHarness != nil }, set: { if !$0 { uninstallHarness = nil } }),
      titleVisibility: .visible, presenting: uninstallHarness
    ) { harness in
      Button("Uninstall", role: .destructive) { Task { await model.uninstallHarness(id: harness.id) } }
    } message: { _ in
      Text("Chats and accounts are kept.")
    }
    .confirmationDialog(
      "Use Global Setting?",
      isPresented: Binding(get: { resetHarness != nil }, set: { if !$0 { resetHarness = nil } }),
      titleVisibility: .visible, presenting: resetHarness
    ) { harness in
      Button("Uninstall", role: .destructive) { Task { await model.resetOverride(id: harness.id) } }
    } message: { harness in
      Text("The global setting will uninstall \(harness.name) here.")
    }
    .task(id: machine.id) {
      model.configure(for: machine.id, dependencies: dependencies)
      await model.refresh()
    }
    .onChange(of: refreshToken) { _, _ in
      Task {
        await model.scan()
        isRefreshing = false
      }
    }
    .onChange(of: environment.harnessCatalogRevision(for: machine.id)) { _, _ in
      Task { await model.refresh() }
    }
  }

  private var client: any CodevisorServerClienting { environment.machines.client(for: machine.id) }

  private var dependencies: HarnessMachineModel.Dependencies {
    HarnessMachineModel.Dependencies(
      loadCatalog: { try await client.listHarnessesWithLifecycle() },
      rescanCatalog: { try await client.rescanHarnesses() },
      setDesiredEnabled: { try await client.setHarnessDesiredEnabled(id: $0, enabled: $1) },
      startUpdate: { try await client.updateHarness(id: $0) },
      startUninstall: { try await client.uninstallHarness(id: $0) },
      resetOverride: { try await client.resetHarnessOverride(id: $0) },
      catalogDidChange: { environment.harnessCatalogDidChange(onServer: machine.id) },
      lifecycleDidChange: { environment.setHarnessLifecycle($0, harnessId: $1, onServer: machine.id) }
    )
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

/// Installed-harness controls live on their own detail page instead of
/// competing for space and meaning in the list row.
struct HarnessDetailScreen: View {
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
    .confirmationDialog("Uninstall \(harness.name)?", isPresented: $confirmsUninstall, titleVisibility: .visible) {
      Button("Uninstall", role: .destructive) { Task { await uninstall() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes the CLI from \(machine.name). Chats and accounts are kept.")
    }
    .confirmationDialog("Use Global Setting?", isPresented: $confirmsReset, titleVisibility: .visible) {
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
