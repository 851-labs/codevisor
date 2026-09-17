import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The iOS harness authentication flow, pinned to one machine: lists the
/// harness's accounts and walks whichever sign-in method the user picks —
/// browser, device-code, API-key, or an attached terminal (Claude's own
/// login flow runs in a PTY on the target machine and renders here).
/// Mirrors the macOS HarnessAuthenticationView's standard flow.
struct HarnessAuthenticationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.harnessMachineSignIn) private var machineSignIn
  @Environment(\.openURL) private var openURL
  @Environment(\.dismiss) private var dismiss

  let serverId: String
  @State var harness: ServerHarness
  var onAuthenticated: () -> Void = {}
  var signInRequest: HarnessMachineSignIn?

  @State private var accounts: [ServerHarnessAccount] = []
  @State private var methods: [ServerHarnessAuthMethod] = []
  @State private var flow: ServerHarnessAuthFlow?
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var loginStep: HarnessLoginStep?
  @State private var pendingAccountId: String?

  private var isAccountPicker: Bool { harness.auth?.supportsMultipleAccounts == true }
  private var selectedAccountId: String? { pendingAccountId ?? accounts.first(where: \.isActive)?.id }
  private var canConfirmSelection: Bool {
    accounts.contains { $0.id == selectedAccountId && canSelect($0) }
  }

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: serverId, isShared: isShared)
  }

  @ViewBuilder
  var body: some View {
    if harness.id == "pi" {
      PiProviderAuthenticationScreen(
        serverId: serverId,
        harness: harness,
        onAuthenticated: onAuthenticated,
        signInRequest: signInRequest
      )
    } else if harness.id == "opencode" {
      OpenCodeProviderAuthenticationScreen(
        serverId: serverId,
        harness: harness,
        onAuthenticated: onAuthenticated,
        signInRequest: signInRequest
      )
    } else {
      standardAuthentication
    }
  }

  private var standardAuthentication: some View {
    accountsForm
      .navigationBarBackButtonHidden(isAccountPicker)
      .interactiveDismissDisabled(isWorking)
      .toolbar {
        if isAccountPicker {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(isWorking)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Add Account", systemImage: "plus") {
              Task { await addAccount() }
            }
            .labelStyle(.iconOnly)
            .disabled(isWorking)
          }
          ToolbarSpacer(.fixed, placement: .topBarTrailing)
          ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm) {
              Task { await confirmSelection() }
            } label: {
              Label("Confirm Selection", systemImage: "checkmark")
            }
            .labelStyle(.iconOnly)
            .disabled(isWorking || !canConfirmSelection)
          }
        } else {
          HarnessAccountsCloseToolbar()
        }
      }
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
      .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
        if isShared { Task { await load() } }
      }
      .onChange(of: environment.configSync.revisionsByNamespace["harness-shared-accounts"]) { _, _ in
        Task { await load() }
      }
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
        if !isShared, !["claude-code", "codex"].contains(harness.id),
          let source = HarnessSharedCredentials(rawValue: harness.id)
        {
          HarnessSharedAccountRows(source: source)
        }
        ForEach(accounts) { account in accountRow(account) }
      }

    }.disabled(isWorking)
  }

  @ViewBuilder
  private func accountRow(_ account: ServerHarnessAccount) -> some View {
    Group {
      if isAccountPicker, canSelect(account) {
        Button {
          pendingAccountId = account.id
        } label: {
          accountRowContent(account)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(account.id == selectedAccountId ? [.isSelected] : [])
      } else {
        accountRowContent(account)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if account.canLogout, canSelect(account) {
        Button {
          Task { await logout(account) }
        } label: {
          Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            .labelStyle(.iconOnly)
        }
        .tint(.blue)
      }
      if account.profileKind == "managed" {
        Button(role: .destructive) {
          Task { await remove(account) }
        } label: {
          Label("Remove", systemImage: "trash")
            .labelStyle(.iconOnly)
        }
      }
    }
  }

  private func accountRowContent(_ account: ServerHarnessAccount) -> some View {
    HStack(spacing: 10) {
      Image(systemName: account.id == selectedAccountId ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(account.id == selectedAccountId ? Color.primary : Color.secondary)
        .accessibilityLabel(account.id == selectedAccountId ? "Selected" : "Not selected")
      VStack(alignment: .leading, spacing: 2) {
        Text(account.label)
        if let status = accountStatus(account) {
          Text(status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer()
      if !canSelect(account), account.canLogin {
        loginControl(account)
      }
    }
    .contentShape(Rectangle())
  }

  private func canSelect(_ account: ServerHarnessAccount) -> Bool {
    account.authState == "authenticated" || account.authState == "notRequired"
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

  private func accountStatus(_ account: ServerHarnessAccount) -> String? {
    switch account.authState {
    case "authenticated", "notRequired": return nil
    case "checking": return "Checking sign-in…"
    case "expired": return account.id.hasPrefix("shared-") ? (account.detail ?? "Sign-in expired") : "Sign-in expired"
    // Plain language, never the probe's `detail` — that carries a crashed
    // CLI's stderr. The cause is summarized and persisted server-side.
    case "error": return "Something went wrong starting the CLI"
    default: return "Not signed in"
    }
  }

}

// MARK: - Actions

extension HarnessAuthenticationScreen {
  private func load() async {
    methods = supportedLoginMethods(harness.auth?.loginMethods ?? [])
    do {
      accounts = try await client.listHarnessAccounts(harnessId: harness.id)
      if let pendingAccountId, !accounts.contains(where: { $0.id == pendingAccountId && canSelect($0) }) {
        self.pendingAccountId = nil
      }
      errorMessage = nil
    } catch { errorMessage = serverErrorMessage(error) }
  }

  private func addAccount() async {
    await perform {
      _ = try await client.createHarnessAccount(harnessId: harness.id, label: nil)
      await load()
    }
  }

  private func confirmSelection() async {
    guard !isWorking, canConfirmSelection, let selectedAccountId else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      accounts = try await client.activateHarnessAccount(harnessId: harness.id, accountId: selectedAccountId)
      await refreshHarness()
      dismiss()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
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
    if isShared, !["claude-code", "codex"].contains(harness.id), method.kind != "apiKey" {
      machineSignIn?(HarnessMachineSignIn())
      return
    }
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
    if isAccountPicker {
      let account = try? await client.probeHarnessAccount(harnessId: harness.id, accountId: accountId)
      await load()
      if let account, canSelect(account), accounts.contains(where: { $0.id == account.id }) {
        pendingAccountId = account.id
      }
      return
    }
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
    if isShared { return }
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
