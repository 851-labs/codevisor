import SwiftUI
import CodevisorCore
import CodevisorCoreMac

struct GeneralSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var permissions = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live
  )
  @State private var showsFullDiskAccessSetup = false

  var body: some View {
    Form {
      generalSection
      permissionsSection
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showsFullDiskAccessSetup, onDismiss: permissions.refresh) {
      FullDiskAccessSetupSheet(model: permissions)
    }
    .onAppear(perform: permissions.refresh)
    .onChange(of: controlActiveState) { _, _ in permissions.refresh() }
  }

  private var permissionsSection: some View {
    Section("Permissions") {
      PermissionRow(
        symbol: "internaldrive",
        title: "Full Disk Access",
        subtitle: "Agents can reach all your files",
        grantedLabel: permissions.isFullDiskAccessGranted ? "Granted" : nil,
        embedded: true
      ) {
        PermissionActionButton("Set Up…") { showsFullDiskAccessSetup = true }
      }
    }
  }

  private var generalSection: some View {
    Section {
      Toggle("Ask before quitting", isOn: confirmBeforeQuitting)
        .toggleStyle(.switch)
      Toggle("Ask before closing a working chat", isOn: confirmBeforeClosingWorkingChat)
        .toggleStyle(.switch)
    } header: {
      Text("General")
    } footer: {
      Text(
        "Shows a confirmation when you press ⌘Q, or close a chat while its agent is still working, so a stray keystroke can't close something you're relying on."
      )
    }
  }

  private var confirmBeforeQuitting: Binding<Bool> {
    Binding(
      get: { environment.settings.confirmBeforeQuitting },
      set: { environment.settings.setConfirmBeforeQuitting($0) }
    )
  }

  private var confirmBeforeClosingWorkingChat: Binding<Bool> {
    Binding(
      get: { environment.settings.confirmBeforeClosingWorkingChat },
      set: { environment.settings.setConfirmBeforeClosingWorkingChat($0) }
    )
  }
}
