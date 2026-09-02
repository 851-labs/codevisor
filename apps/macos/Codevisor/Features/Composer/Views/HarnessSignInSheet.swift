import CodevisorCore
import SwiftUI

/// The in-flow sign-in surface: presents the full harness authentication
/// experience (browser, device-code, or API-key flows) for ONE harness on
/// ONE machine when an auth-dead chat needs it. Reuses the
/// settings/onboarding authentication view verbatim, pinned to the target
/// machine.
struct HarnessSignInSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  let serverId: String
  let harnessId: String
  @State private var harness: ServerHarness?
  @State private var loadFailed = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Button("Done") { finish() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      Divider()
      content
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 500)
    .environment(\.settingsMachineId, serverId)
    .task {
      guard harness == nil else { return }
      harness = try? await environment.machines.client(for: serverId)
        .listHarnesses()
        .first { $0.id == harnessId }
      loadFailed = harness == nil
    }
    .onDisappear {
      // Whatever happened in the flow, the machine's catalog is now
      // suspect — the revision bump refreshes any mounted composer.
      environment.harnessCatalogDidChange(onServer: serverId)
    }
  }

  private var title: String {
    let machine = environment.machines.machine(for: serverId)?.name ?? "this machine"
    return "Sign in to \(harness?.name ?? harnessId) on \(machine)"
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
        showsHeader: false
      )
    } else if loadFailed {
      ContentUnavailableView {
        Label("Harness Unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text("Couldn't load the harness from the machine. Check its connection and try again.")
      }
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func finish() {
    environment.harnessCatalogDidChange(onServer: serverId)
    dismiss()
  }
}

/// Sheet-item wrappers: ServerHarness itself is not Identifiable.
struct HarnessSignInTarget: Identifiable {
  let harnessId: String
  var id: String { harnessId }
}

extension View {
  /// Presents the sign-in sheet bound to an optional harness id (auth-dead
  /// chats know only the id).
  func harnessSignInSheet(harnessId: Binding<String?>, serverId: String) -> some View {
    sheet(
      item: Binding(
        get: { harnessId.wrappedValue.map(HarnessSignInTarget.init(harnessId:)) },
        set: { harnessId.wrappedValue = $0?.harnessId }
      )
    ) { target in
      HarnessSignInSheet(serverId: serverId, harnessId: target.harnessId)
    }
  }
}
