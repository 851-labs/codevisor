import CodevisorCore
import SwiftUI

struct SandboxEditProviderPage: View {
  @Environment(AppEnvironment.self) private var environment
  let provider: ServerSandboxProvider
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let onDone: () -> Void
  @State private var draft: SandboxProviderDraft
  @State private var status: String?
  @State private var removal: SandboxProviderRemoval?

  init(
    provider: ServerSandboxProvider,
    vendor: ServerSandboxVendor,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    onDone: @escaping () -> Void
  ) {
    self.provider = provider
    self.vendor = vendor
    self.model = model
    self.client = client
    self.onDone = onDone
    _draft = State(initialValue: SandboxProviderDraft(vendor: vendor, provider: provider))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "Edit Provider", actionTitle: "Save", canAct: draft.canSave, status: status,
      errorMessage: model.errorMessage, onAction: save
    ) {
      SandboxProviderFields(draft: $draft, vendor: vendor, model: model) {
        SandboxDeleteFooter(
          title: "Delete Provider…", help: "Delete this provider and its profiles", onDelete: prepareDeletion)
      }
      SandboxDeleteSection(title: "Delete Provider", onDelete: prepareDeletion)
    }
    .confirmationDialog(
      removal?.title ?? "", isPresented: presence($removal), titleVisibility: .visible, presenting: removal
    ) { _ in
      Button("Delete Provider", role: .destructive, action: deleteProvider)
      Button("Cancel", role: .cancel) {}
    } message: { removal in
      Text(removal.message)
    }
    .onAppear { model.errorMessage = nil }
  }

  private var reachableMachines: [SandboxMachine] {
    let reachable = SandboxMachine.reachable(in: environment.machines)
    return reachable.isEmpty ? [SandboxMachine(name: "", client: client)] : reachable
  }

  private func save() {
    status = "Saving…"
    Task {
      let outcome = await model.save(draft, using: client)
      status = nil
      switch outcome {
      case .saved: onDone()
      case let .choose(field): draft.offer(field)
      case .failed: break
      }
    }
  }

  private func prepareDeletion() {
    let offline = SandboxMachine.offlineNames(in: environment.machines)
    status = "Checking…"
    Task {
      removal = await model.removal(of: provider, on: reachableMachines, offline: offline)
      status = nil
    }
  }

  private func deleteProvider() {
    status = "Deleting…"
    Task {
      let deleted = await model.delete(provider, on: reachableMachines)
      status = nil
      if deleted { onDone() }
    }
  }

  private func presence<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
  }
}
