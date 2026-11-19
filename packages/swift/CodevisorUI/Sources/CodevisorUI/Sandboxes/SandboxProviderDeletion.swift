import CodevisorCore
import SwiftUI

public struct SandboxProviderDeletion: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var provider: ServerSandboxProvider?
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  @Binding var status: String?
  let onDeleted: () -> Void
  @State private var removal: SandboxProviderRemoval?

  public init(
    provider: Binding<ServerSandboxProvider?>,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    status: Binding<String?> = .constant(nil),
    onDeleted: @escaping () -> Void = {}
  ) {
    _provider = provider
    self.model = model
    self.client = client
    _status = status
    self.onDeleted = onDeleted
  }

  public func body(content: Content) -> some View {
    content
      .task(id: provider?.id) { await prepare() }
      .confirmationDialog(
        removal?.title ?? "", isPresented: isConfirming, titleVisibility: .visible, presenting: provider
      ) { provider in
        Button("Delete Provider", role: .destructive) { delete(provider) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text(removal?.message ?? "")
      }
  }

  private var isConfirming: Binding<Bool> {
    Binding(get: { removal != nil }, set: { if !$0 { finish() } })
  }

  private var reachableMachines: [SandboxMachine] {
    let reachable = SandboxMachine.reachable(in: environment.machines)
    return reachable.isEmpty ? [SandboxMachine(name: "", client: client)] : reachable
  }

  private func prepare() async {
    guard let provider else { return }

    let offline = SandboxMachine.offlineNames(in: environment.machines)
    status = "Checking…"
    removal = await model.removal(of: provider, on: reachableMachines, offline: offline)
    status = nil
  }

  private func finish() {
    removal = nil
    provider = nil
  }

  private func delete(_ provider: ServerSandboxProvider) {
    status = "Deleting…"
    Task {
      let deleted = await model.delete(provider, on: reachableMachines)
      status = nil
      if deleted { onDeleted() }
    }
  }
}
