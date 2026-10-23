import CodevisorClient
import SwiftUI

struct NewEphemeralMachineDialog: ViewModifier {
  @Binding var isPresented: Bool
  let projectId: UUID?
  let client: any CodevisorServerClienting
  @State private var providers: [ServerEphemeralProvider] = []
  @State private var outcome: String?

  func body(content: Content) -> some View {
    content
      .confirmationDialog("New Ephemeral Machine", isPresented: $isPresented, titleVisibility: .visible) {
        ForEach(configuredProviders) { provider in
          Button(provider.displayName) { start(provider) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(message)
      }
      .alert(outcome ?? "", isPresented: showsOutcome) {
        Button("OK", role: .cancel) {}
      }
      .task(id: isPresented) {
        guard isPresented else { return }
        providers = (try? await client.ephemeralProviders()) ?? []
      }
  }

  private var configuredProviders: [ServerEphemeralProvider] {
    projectId == nil ? [] : providers.filter(\.configured)
  }

  private var message: String {
    if projectId == nil { return "Pick a project first." }
    if configuredProviders.isEmpty { return "Add a provider's credentials first." }
    return "Starts a throwaway machine with a workspace for this project. Archiving the workspace destroys it."
  }

  private var showsOutcome: Binding<Bool> {
    Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
  }

  private func start(_ provider: ServerEphemeralProvider) {
    guard let projectId else { return }
    Task {
      do {
        let machine = try await client.createEphemeralMachine(provider: provider.id, projectId: projectId)
        outcome = "Setting up \(machine.name). Its workspace appears in the sidebar in a few minutes."
      } catch {
        outcome = "Couldn't start a \(provider.displayName) machine: \(error.localizedDescription)"
      }
    }
  }
}
