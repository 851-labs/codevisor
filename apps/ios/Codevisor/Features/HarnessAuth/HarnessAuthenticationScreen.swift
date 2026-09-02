import CodevisorCore
import SwiftUI
import UIKit

/// The iOS harness authentication flow, pinned to one machine: lists the
/// harness's accounts and walks whichever sign-in method the user picks —
/// browser, device-code, API-key, or an attached terminal (Claude's own
/// login flow runs in a PTY on the target machine and renders here).
/// Mirrors the macOS HarnessAuthenticationView's standard flow.
struct HarnessAuthenticationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openURL) private var openURL

  let serverId: String
  @State var harness: ServerHarness
  var onAuthenticated: () -> Void = {}

  @State private var accounts: [ServerHarnessAccount] = []
  @State private var methods: [ServerHarnessAuthMethod] = []
  @State private var flow: ServerHarnessAuthFlow?
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var loginStep: HarnessLoginStep?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: serverId)
  }

  @ViewBuilder
  var body: some View {
    if harness.id == "pi" {
      PiProviderAuthenticationScreen(
        serverId: serverId,
        harness: harness,
        onAuthenticated: onAuthenticated
      )
    } else if harness.id == "opencode" {
      OpenCodeProviderAuthenticationScreen(
        serverId: serverId,
        harness: harness,
        onAuthenticated: onAuthenticated
      )
    } else {
      standardAuthentication
    }
  }

  private var standardAuthentication: some View {
    accountsForm
      .sheet(item: $loginStep) { step in
        HarnessLoginStepScreen(
          harness: harness,
          step: step,
          submitCode: { code in await submitPastedCode(code) },
          submitApiKey: { account, method, key in
            await submitApiKey(account: account, method: method, key: key)
          },
          cancel: {
            loginStep = nil
            Task { await cancelFlow() }
          }
        )
      }
      .task { await load() }
      .onDisappear {
        guard let flow else { return }
        Task {
          try? await client.cancelHarnessLogin(
            harnessId: harness.id,
            accountId: flow.accountId,
            flowId: flow.id
          )
        }
      }
  }

  // MARK: - Layout

  private var accountsForm: some View {
    Form {
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }

      Section(accountSectionTitle) {
        ForEach(accounts) { account in accountRow(account) }
        if harness.auth?.supportsMultipleAccounts == true {
          Button {
            Task { await addAccount() }
          } label: {
            Label("Add Account", systemImage: "plus")
          }
          .disabled(isWorking)
        }
      }

    }
  }

  @ViewBuilder
  private func accountRow(_ account: ServerHarnessAccount) -> some View {
    HStack(spacing: 10) {
      Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(account.isActive ? Color.primary : Color.secondary)
        .accessibilityLabel(account.isActive ? "Selected" : "Not selected")
      VStack(alignment: .leading, spacing: 2) {
        Text(account.label)
        Text(accountStatus(account))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      if account.authState == "authenticated" || account.authState == "notRequired" {
        if !account.isActive {
          Button("Use") { Task { await activate(account) } }
            .buttonStyle(.borderless)
        }
      } else if account.canLogin {
        loginControl(account)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if account.canLogout,
        account.authState == "authenticated" || account.authState == "notRequired"
      {
        Button("Sign Out") { Task { await logout(account) } }
      }
      if account.profileKind == "managed" {
        Button("Remove", role: .destructive) { Task { await remove(account) } }
      }
    }
  }

  @ViewBuilder
  private func loginControl(_ account: ServerHarnessAccount) -> some View {
    if methods.count > 1 {
      Menu("Sign In") {
        ForEach(methods) { method in
          Button(method.name) { selectLoginMethod(method, for: account) }
        }
      }
    } else {
      Button(methods.first?.name ?? "Sign In") {
        if let method = methods.first {
          selectLoginMethod(method, for: account)
        } else {
          Task { await login(account, methodId: nil) }
        }
      }
      .buttonStyle(.borderless)
    }
  }

  private var authProgress: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Waiting for sign-in…")
        .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel") { Task { await cancelFlow() } }
    }
  }

  private var accountSectionTitle: String {
    harness.auth?.supportsMultipleAccounts == true ? "Accounts" : "Configuration"
  }

  private func accountStatus(_ account: ServerHarnessAccount) -> String {
    switch account.authState {
    case "authenticated": return account.email.map { "Signed in as \($0)" } ?? "Signed in"
    case "notRequired": return "No sign-in required"
    case "checking": return "Checking sign-in…"
    case "expired": return "Sign-in expired"
    // Plain language, never the probe's `detail` — that carries a crashed
    // CLI's stderr. The cause is summarized and persisted server-side.
    case "error": return "Something went wrong starting the CLI"
    default: return "Not signed in"
    }
  }

  // MARK: - Actions

  private func load() async {
    methods = supportedLoginMethods(harness.auth?.loginMethods ?? [])
    do {
      accounts = try await client.listHarnessAccounts(harnessId: harness.id)
      errorMessage = nil
    } catch { errorMessage = serverErrorMessage(error) }
  }

  private func addAccount() async {
    await perform {
      _ = try await client.createHarnessAccount(harnessId: harness.id, label: nil)
      await load()
    }
  }

  private func activate(_ account: ServerHarnessAccount) async {
    await perform {
      accounts = try await client.activateHarnessAccount(harnessId: harness.id, accountId: account.id)
    }
    await refreshHarness()
  }

  private func logout(_ account: ServerHarnessAccount) async {
    await perform {
      _ = try await client.logoutHarnessAccount(harnessId: harness.id, accountId: account.id)
      await load()
    }
    await refreshHarness()
  }

  private func remove(_ account: ServerHarnessAccount) async {
    await perform {
      try await client.removeHarnessAccount(harnessId: harness.id, accountId: account.id)
      await load()
    }
    await refreshHarness()
  }

  private func selectLoginMethod(_ method: ServerHarnessAuthMethod, for account: ServerHarnessAccount) {
    if method.kind == "apiKey" {
      loginStep = .apiKey(account: account, method: method)
    } else {
      Task { await login(account, methodId: method.id) }
    }
  }

  /// Completes a pasteCode flow; returns an error message for the sheet.
  private func submitPastedCode(_ code: String) async -> String? {
    guard let flow else { return "This sign-in attempt has expired — start again." }
    do {
      let next = try await client.answerHarnessLogin(
        harnessId: harness.id,
        accountId: flow.accountId,
        flowId: flow.id,
        code: code
      )
      if next.kind == "complete" {
        self.flow = nil
        loginStep = nil
        await finishAuthentication(accountId: flow.accountId)
      }
      return nil
    } catch {
      return serverErrorMessage(error)
    }
  }

  /// Runs an API-key login; returns an error message for the sheet.
  private func submitApiKey(
    account: ServerHarnessAccount,
    method: ServerHarnessAuthMethod,
    key: String
  ) async -> String? {
    do {
      let next = try await client.loginHarnessAccount(
        harnessId: harness.id,
        accountId: account.id,
        methodId: method.id,
        apiKey: key
      )
      if next.kind == "complete" {
        loginStep = nil
        await finishAuthentication(accountId: account.id)
      }
      return nil
    } catch {
      return serverErrorMessage(error)
    }
  }

  private func login(_ account: ServerHarnessAccount, methodId: String?, apiKey: String? = nil) async {
    await perform {
      let next = try await client.loginHarnessAccount(
        harnessId: harness.id,
        accountId: account.id,
        methodId: methodId,
        apiKey: apiKey
      )
      flow = next.kind == "complete" ? nil : next
      loginStep = next.kind == "complete" ? nil : .flow(next)
      if next.kind != "deviceCode",
        let value = next.url ?? next.verificationUrl,
        let url = URL(string: value)
      {
        openURL(url)
      }
      if next.kind == "complete" {
        await finishAuthentication(accountId: account.id)
        return
      }
      Task { await poll(accountId: account.id) }
    }
  }

  private func poll(accountId: String) async {
    for _ in 0..<300 where !Task.isCancelled && flow != nil {
      try? await Task.sleep(for: .seconds(2))
      guard let account = try? await client.probeHarnessAccount(harnessId: harness.id, accountId: accountId)
      else { continue }
      if account.authState == "authenticated" || account.authState == "notRequired" {
        flow = nil
        loginStep = nil
        await finishAuthentication(accountId: accountId)
        return
      }
      if account.authState == "error" || account.authState == "expired" {
        // Friendly text only — `detail` carries the probe's technical
        // cause (up to a crashed CLI's stderr) and never reaches the UI.
        let message =
          account.authState == "expired"
          ? "Sign-in expired. Try signing in again."
          : "Couldn't verify sign-in."
        await cancelFlow()
        await load()
        errorMessage = message
        return
      }
    }
    // The waiting spinner must never outlive the wait: a login that
    // hasn't completed after ten minutes is not going to.
    guard !Task.isCancelled, flow != nil else { return }
    await cancelFlow()
    await load()
    errorMessage = "Sign-in timed out. Try signing in again."
  }

  private func finishAuthentication(accountId: String) async {
    if let activated = try? await client.activateHarnessAccount(
      harnessId: harness.id,
      accountId: accountId
    ) {
      accounts = activated
    } else {
      await load()
    }
    await refreshHarness()
    if harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired" {
      onAuthenticated()
    }
  }

  private func cancelFlow() async {
    guard let current = flow else { return }
    flow = nil
    try? await client.cancelHarnessLogin(
      harnessId: harness.id,
      accountId: current.accountId,
      flowId: current.id
    )
  }

  private func refreshHarness() async {
    if let updated = try? await environment.refreshHarnessAuthentication(
      harnessId: harness.id, onServer: serverId)
    {
      harness = updated
      methods = supportedLoginMethods(updated.auth?.loginMethods ?? methods)
    }
  }

  private func supportedLoginMethods(
    _ candidates: [ServerHarnessAuthMethod]
  ) -> [ServerHarnessAuthMethod] {
    guard harness.id == "codex", serverId != CodevisorMachine.local.id else {
      return candidates
    }
    return candidates.filter { $0.id != "chatgpt" }
  }

  private func perform(_ operation: () async throws -> Void) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await operation()
      errorMessage = nil
    } catch { errorMessage = serverErrorMessage(error) }
  }
}
