import CodevisorCore
import CodevisorUI
import SwiftUI

/// Connects one machine's harness model to the app environment and owns the
/// pane's presentation. Section rendering lives in `HarnessMachineSections`.
struct HarnessMachinePane: View {
  @Bindable private var settingsRouter = SettingsRouter.shared
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let machine: CodevisorMachine
  var opensPendingAccountRequest = false

  @State private var model = HarnessMachineModel()
  @State private var authenticationHarness: ServerHarness?
  @State private var catalogReadyServerId: String?
  @State private var detailHarness: ServerHarness?
  @State private var showsCustomEditor = false
  @State private var editingCustomHarnessId: String?

  private var serverId: String { machine.id }

  var body: some View {
    HarnessMachineSections(
      model: model,
      onScan: {
        Task { presentAuthentication(await model.scan()) }
      },
      onAuthenticate: { authenticationHarness = $0 },
      onShowDetail: { detailHarness = $0 },
      onEditCustom: { id in
        editingCustomHarnessId = id
        showsCustomEditor = true
      }
    )
    .task(id: serverId) {
      catalogReadyServerId = nil
      model.configure(for: serverId, dependencies: modelDependencies)
      let automaticCandidate = await model.scan()
      catalogReadyServerId = model.isScanning ? nil : serverId
      if !presentRequestedAccountManager() {
        presentAuthentication(automaticCandidate)
      }
    }
    .onChange(of: environment.harnessCatalogRevision(for: serverId)) { _, _ in
      // Lifecycle events and mutations invalidate the light catalog.
      Task {
        let automaticCandidate = await model.refresh()
        catalogReadyServerId = model.isScanning ? nil : serverId
        if !presentRequestedAccountManager() {
          presentAuthentication(automaticCandidate)
        }
      }
    }
    .onChange(of: settingsRouter.pendingHarnessAccountRequest, initial: true) {
      _, _ in
      presentRequestedAccountManager()
    }
    .sheet(item: $authenticationHarness) { harness in
      HarnessAuthenticationView(harness: harness) { model.replaceHarness($0) }
    }
    .sheet(item: $detailHarness) { harness in
      HarnessDetailSheet(harness: harness)
    }
    .sheet(isPresented: $showsCustomEditor) {
      CustomHarnessEditorSheet(editingId: editingCustomHarnessId) { harnesses in
        model.replaceCatalog(harnesses, notifying: true)
      }
    }
    .alert(
      model.operationError?.title ?? "",
      isPresented: Binding(
        get: { model.operationError != nil },
        set: { if !$0 { model.dismissOperationError() } }
      ),
      presenting: model.operationError
    ) { _ in
      Button("OK") {}
        .settingsActionTint(theme)
    } message: { error in
      Text(error.message)
    }
    .environment(\.settingsMachineId, machine.id)
  }

  private var modelDependencies: HarnessMachineModel.Dependencies {
    let environment = environment
    let serverId = serverId
    return HarnessMachineModel.Dependencies(
      loadCatalog: {
        try await environment.harnessService(for: serverId).allHarnesses()
      },
      rescanCatalog: {
        try await environment.harnessService(for: serverId).rescanHarnesses()
      },
      setDesiredEnabled: { id, enabled in
        try await environment.machines.client(for: serverId)
          .setHarnessDesiredEnabled(id: id, enabled: enabled)
      },
      startUpdate: { id in
        try await environment.machines.client(for: serverId).updateHarness(id: id)
      },
      catalogDidChange: {
        environment.harnessCatalogDidChange(onServer: serverId)
      },
      lifecycleDidChange: { lifecycle, id in
        environment.setHarnessLifecycle(lifecycle, harnessId: id, onServer: serverId)
      }
    )
  }

  private func presentAuthentication(_ harness: ServerHarness?) {
    guard authenticationHarness == nil, let harness else { return }
    authenticationHarness = harness
  }

  /// Presents the deep-linked account manager once this machine's catalog is
  /// ready. A failed catalog load consumes the request instead of reopening it
  /// during unrelated navigation later.
  @discardableResult
  private func presentRequestedAccountManager() -> Bool {
    guard opensPendingAccountRequest,
      catalogReadyServerId == serverId,
      let request = settingsRouter.pendingHarnessAccountRequest,
      request.machineId == serverId
    else { return false }
    guard let harness = model.harness(id: request.harnessId) else {
      if !model.isScanning {
        settingsRouter.pendingHarnessAccountRequest = nil
      }
      return false
    }
    settingsRouter.pendingHarnessAccountRequest = nil
    presentAuthentication(harness)
    return true
  }
}
