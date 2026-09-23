import CodevisorCore
import CodevisorUI
import SwiftUI

/// The in-flow sign-in surface: presents the full harness authentication
/// experience (browser, device-code, or API-key flows) for ONE harness on
/// ONE machine when an auth-dead chat needs it. Reuses the
/// settings/onboarding authentication view verbatim, pinned to the target
/// machine.
struct HarnessSignInSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme

  let serverId: String
  let harnessId: String
  /// Lands in the sign-in flow rather than the account list.
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
          .settingsActionTint(theme)
          .keyboardShortcut(.defaultAction)
      }
    }
    .sheetSize(.list)
    .themedSurface(.sheet)
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

/// Sheet-item wrappers: ServerHarness itself is not Identifiable.
struct HarnessSignInTarget: Identifiable {
  let harnessId: String
  var id: String { harnessId }
}

extension View {
  /// Presents sign-in for an optional harness id (auth-dead chats know only
  /// the id and the machine they ran on). Fleet-shared harnesses land on the
  /// fleet's accounts sheet with that machine as the preferred host; only
  /// harnesses whose accounts truly live on one machine get its flow.
  func harnessSignInSheet(harnessId: Binding<String?>, serverId: String) -> some View {
    modifier(HarnessSignInSheetModifier(harnessId: harnessId, serverId: serverId))
  }
}

private struct HarnessSignInSheetModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var harnessId: String?
  let serverId: String

  func body(content: Content) -> some View {
    content.sheet(
      item: Binding(
        get: { harnessId.map(HarnessSignInTarget.init(harnessId:)) },
        set: { harnessId = $0?.harnessId }
      )
    ) { target in
      if HarnessRegistry.descriptor(for: target.harnessId).sharesFleetAccounts {
        HarnessAccountsSheet(
          harnessId: target.harnessId,
          harnessName: HarnessRegistry.displayName(
            for: target.harnessId,
            reported: HarnessFleet.settings(environment.configSync).first { $0.id == target.harnessId }?.name),
          preferredMachineId: serverId
        ) { machineId, harness, request in
          HarnessAuthenticationView(harness: harness, onChange: { _ in }, showsHeader: false, signInRequest: request)
            .environment(\.settingsMachineId, machineId)
        }
        .onDisappear { environment.harnessCatalogDidChange(onServer: serverId) }
      } else {
        HarnessSignInSheet(serverId: serverId, harnessId: target.harnessId)
      }
    }
  }
}
