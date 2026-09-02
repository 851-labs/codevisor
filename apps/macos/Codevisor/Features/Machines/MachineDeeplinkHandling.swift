import CodevisorCore
import SwiftUI

/// codevisor://add-machine deeplink handling: parse, confirm, add, and route
/// to the Machines settings tab. Lives in its own modifier so RootView's
/// modifier chain stays within the Swift type checker's budget.
struct MachineDeeplinkHandling: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings
  @State private var pendingDeeplink: MachineDeeplink?
  @State private var deeplinkError: String?

  func body(content: Content) -> some View {
    content
      // Never auto-add: the token grants full agent access, so an
      // explicit confirmation always sits between the link and the
      // machine list.
      .onOpenURL { url in
        guard let deeplink = MachineDeeplink.parse(url) else { return }
        pendingDeeplink = deeplink
      }
      .alert(
        "Add Remote Machine?",
        isPresented: confirmPresented,
        presenting: pendingDeeplink
      ) { deeplink in
        Button("Add \(deeplink.displayName)") { confirm(deeplink, syncConfig: true) }
        Button("Add Without Syncing Config") { confirm(deeplink, syncConfig: false) }
        Button("Cancel", role: .cancel) { pendingDeeplink = nil }
      } message: { deeplink in
        Text(
          """
          “\(deeplink.displayName)” (\(deeplink.hostWithPort)) will be added to your \
          machines. Codevisor will be able to run agents and read files on it.
          """
        )
      }
      .alert(
        "Couldn't Add Machine",
        isPresented: errorPresented,
        presenting: deeplinkError
      ) { _ in
        Button("OK", role: .cancel) { deeplinkError = nil }
      } message: { error in
        Text(error)
      }
  }

  private var confirmPresented: Binding<Bool> {
    Binding(
      get: { pendingDeeplink != nil },
      set: { if !$0 { pendingDeeplink = nil } }
    )
  }

  private var errorPresented: Binding<Bool> {
    Binding(
      get: { deeplinkError != nil },
      set: { if !$0 { deeplinkError = nil } }
    )
  }

  /// Adds (or, for an existing address, re-tokens) the machine from a
  /// confirmed deeplink, makes it the new-composer default, then lands the
  /// user on Machines settings so the connection's status is visible.
  private func confirm(_ deeplink: MachineDeeplink, syncConfig: Bool) {
    defer { pendingDeeplink = nil }
    do {
      let machine = try environment.machines.addRemote(
        host: deeplink.hostWithPort,
        name: deeplink.name,
        token: deeplink.token
      )
      environment.composerDefaults.rememberNewWorkspaceServer(serverId: machine.id)
      environment.machines.applySyncParticipation(machine.id, enabled: syncConfig)
      SettingsRouter.shared.showMachines()
      openSettings()
    } catch {
      deeplinkError = String(describing: error)
    }
  }
}
