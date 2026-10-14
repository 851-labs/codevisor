import CodevisorCore
import CodevisorUI
import SwiftUI

extension Notification.Name {
  static let codevisorHarnessSignIn = Notification.Name("codevisor.harness-sign-in")
}

struct HarnessSignInRequest: Identifiable {
  let serverId: String
  let harnessId: String
  var initialHarness: ServerHarness?
  var startsSignIn = false

  var id: String { "\(serverId)|\(harnessId)" }

  func post() {
    NotificationCenter.default.post(
      name: .codevisorHarnessSignIn,
      object: nil,
      userInfo: ["serverId": serverId, "harnessId": harnessId]
    )
  }

  init(serverId: String, harnessId: String, initialHarness: ServerHarness? = nil, startsSignIn: Bool = false) {
    self.serverId = serverId
    self.harnessId = harnessId
    self.initialHarness = initialHarness
    self.startsSignIn = startsSignIn
  }

  init?(notification: Notification) {
    guard
      let serverId = notification.userInfo?["serverId"] as? String,
      let harnessId = notification.userInfo?["harnessId"] as? String
    else { return nil }
    self.init(serverId: serverId, harnessId: harnessId)
  }
}

struct HarnessSignInSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  let request: HarnessSignInRequest

  @State private var harness: ServerHarness?
  @State private var loadFailed = false

  var body: some View {
    if HarnessRegistry.descriptor(for: request.harnessId).sharesFleetAccounts {
      HarnessAccountsSheet(
        harnessId: request.harnessId,
        harnessName: HarnessRegistry.displayName(
          for: request.harnessId,
          reported: HarnessFleet.settings(environment.configSync).first { $0.id == request.harnessId }?.name),
        startsSignIn: request.startsSignIn,
        preferredMachineId: request.serverId
      ) { machineId, harness, signInRequest in
        HarnessAuthenticationScreen(serverId: machineId ?? "", harness: harness, signInRequest: signInRequest)
      }
      .onDisappear { environment.harnessCatalogDidChange(onServer: request.serverId) }
    } else {
      machineSheet
    }
  }

  private var machineSheet: some View {
    NavigationStack {
      content
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if harness == nil {
            HarnessAccountsCloseToolbar()
          }
        }
    }
    .environment(\.harnessAccountsDismiss, HarnessAccountsDismissAction { finish() })
    .task {
      guard harness == nil else { return }
      if let initial = request.initialHarness {
        harness = initial
        return
      }
      harness = try? await environment.machines.client(for: request.serverId)
        .listHarnesses()
        .first { $0.id == request.harnessId }
      loadFailed = harness == nil
    }
    .onDisappear {
      environment.harnessCatalogDidChange(onServer: request.serverId)
    }
  }

  private var title: String {
    HarnessRegistry.displayName(for: request.harnessId, reported: harness?.name)
  }

  @ViewBuilder
  private var content: some View {
    if let harness {
      HarnessAuthenticationScreen(
        serverId: request.serverId,
        harness: harness,
        onAuthenticated: { finish() },
        signInRequest: request.startsSignIn
          ? HarnessMachineSignIn(profileId: request.harnessId == "opencode" ? "default" : nil) : nil
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
    environment.harnessCatalogDidChange(onServer: request.serverId)
    dismiss()
  }
}

extension View {
  func harnessSignInSheet(
    request: Binding<HarnessSignInRequest?>,
    onDismiss: @escaping () -> Void = {}
  ) -> some View {
    sheet(item: request, onDismiss: onDismiss) { pending in
      HarnessSignInSheet(request: pending)
    }
  }
}
