import CodevisorCore
import CodevisorUI
import SwiftUI

struct HarnessSignInSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  let serverId: String
  let harnessId: String
  var startsSignIn = false
  @State private var harness: ServerHarness?
  @State private var loadFailed = false

  var body: some View {
    NavigationStack {
      content.navigationTitle(title)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SheetFooter {
        Button("Done") { finish() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .sheetSize(.list)
    .environment(\.settingsMachineId, serverId)
    .task {
      guard harness == nil else { return }
      harness = try? await environment.machines.client(for: serverId)
        .listHarnesses()
        .first { $0.id == harnessId }
      loadFailed = harness == nil
    }
    .onDisappear {
      environment.harnessCatalogDidChange(onServer: serverId)
    }
  }

  private var title: String {
    let machine = environment.machines.machine(for: serverId)?.name ?? "this machine"
    return "Sign in to \(HarnessRegistry.displayName(for: harnessId, reported: harness?.name)) on \(machine)"
  }

  @ViewBuilder
  private var content: some View {
    if let harness {
      HarnessAuthenticationView(
        harness: harness,
        onChange: { updated in
          self.harness = updated
          if updated.auth?.state == "authenticated" {
            finish()
          }
        },
        showsHeader: false,
        signInRequest: startsSignIn ? HarnessMachineSignIn(profileId: harnessId == "opencode" ? "default" : nil) : nil
      )
    } else if loadFailed {
      ContentUnavailableView {
        Label("Harness Unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text("Couldn't load the harness from the machine. Check its connection and try again.")
      }
    } else {
      SheetLoadingView("Loading harness…")
    }
  }

  private func finish() {
    environment.harnessCatalogDidChange(onServer: serverId)
    dismiss()
  }
}
