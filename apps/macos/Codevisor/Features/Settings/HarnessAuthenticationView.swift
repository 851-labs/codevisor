import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct HarnessAuthenticationView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.harnessMachineSignIn) private var machineSignIn
  @Environment(\.settingsMachineId) private var settingsMachineId

  /// The machine this view operates on — pinned by the machine-scoped
  /// Settings page that presented it, else the app's selected machine
  /// (onboarding, previews).
  private var scopedServerId: String {
    settingsMachineId ?? environment.defaultComposerServerId
  }

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: scopedServerId, isShared: isShared)
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme

  let harness: ServerHarness
  var onChange: (ServerHarness) -> Void
  /// Settings/onboarding render this view standalone and want its own
  /// title and Done footer. The composer's sign-in sheet brings its own
  /// chrome (with machine context) and turns this off.
  var showsHeader = true
  var signInRequest: HarnessMachineSignIn?

  @State private var model = HarnessAccountListModel()
  @State private var didOpenSignInRequest = false
  @State private var choosesSignInMethod = false
  @State private var draftAccount: ServerHarnessAccount?
  @State private var pollingTask: Task<Void, Never>?
  @State private var methods: [ServerHarnessAuthMethod] = []
  @State private var flow: ServerHarnessAuthFlow?
  /// The focused modal step a sign-in attempt runs in.
  @State private var loginStep: HarnessLoginStep?

  @ViewBuilder
  var body: some View {
    if harness.id == "pi" {
      PiProviderAuthenticationView(
        harness: harness, onChange: onChange, showsHeader: showsHeader, signInRequest: signInRequest)
    } else if harness.id == "opencode" {
      OpenCodeProviderAuthenticationView(
        harness: harness, onChange: onChange, showsHeader: showsHeader, signInRequest: signInRequest)
    } else {
      standardAuthentication
    }
  }

  private var standardAuthentication: some View {
    Group {
      if showsHeader {
        NavigationStack {
          VStack(spacing: 0) {
            accountsForm
            SheetFooter {
              Button("Done") { dismiss() }
                .settingsActionTint(theme)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            }
          }
          .navigationTitle(authenticationTitle)
        }
        .frame(width: 560, height: 380)
      } else {
        accountsForm
      }
    }
    .interactiveDismissDisabled(model.isWorking)
    .task { await load() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await load() } }
    }
    // Each sign-in attempt is one focused task in its own sheet — the
    // accounts list never grows inline flow UI.
    .sheet(item: $loginStep, onDismiss: { Task { await cancelFlow() } }) { step in
      HarnessLoginStepSheet(
        harness: harness,
        step: step,
        submitCode: { code in await submitPastedCode(code) },
        submitApiKey: { account, method, key in
          await submitApiKey(account: account, method: method, key: key)
        },
        cancel: { loginStep = nil }
      )
    }
    .onChange(of: environment.configSync.revisionsByNamespace["harness-shared-accounts"]) { _, _ in
      Task { await load() }
    }
    .onDisappear {
      pollingTask?.cancel()
      Task { await cancelFlow() }
    }
  }

  @ViewBuilder private var accountsForm: some View {
    if choosesSignInMethod {
      HarnessSignInMethods(methods: methods, model: model) { method in
        Task { await beginSignIn(method: method) }
      }
    } else {
      HarnessAccountsContent(harnessId: harness.id, harnessName: harness.name, model: model, retry: load) {
        populatedAccountsForm
      } signIn: {
        addAccountControl("Sign In")
      }
    }
  }

  private var populatedAccountsForm: some View {
    Form {
      if let errorMessage = model.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        if !isShared, !["claude-code", "codex"].contains(harness.id),
          let source = HarnessSharedCredentials(rawValue: harness.id)
        {
          HarnessSharedAccountRows(source: source)
        }
        ForEach(model.accounts) { account in accountRow(account) }
      } footer: {
        if harness.auth?.supportsMultipleAccounts == true {
          addAccountControl("Add Account")
            .font(.body)
            .settingsActionTint(theme)
            .disabled(model.isWorking)
        }
      }
    }
    .formStyle(.grouped)
    .disabled(model.isWorking)
  }

  @ViewBuilder
  private func accountRow(_ account: ServerHarnessAccount) -> some View {
    HStack(spacing: 10) {
      Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(account.isActive ? theme.textPrimary : theme.textSecondary)
        .accessibilityLabel(account.isActive ? "Selected" : "Not selected")
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(account.label)
          if !isShared, account.isActive, let scope = account.selectionScope {
            Text(scope == "machine" ? "Override" : "Shared").font(.caption).foregroundStyle(.secondary)
          }
        }
        if let status = accountStatus(account) {
          Text(status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .help(status)
        }
      }
      Spacer()
      if account.authState == "authenticated" || account.authState == "notRequired" {
        if !account.isActive {
          Button("Use") { Task { await activate(account) } }
            .settingsActionTint(theme)
        }
        if account.canLogout {
          Button("Sign Out") { Task { await logout(account) } }
            .settingsActionTint(theme)
        }
      } else if account.canLogin {
        loginControl(account)
      }
      if account.profileKind == "managed" {
        Menu {
          Button("Remove Account", role: .destructive) { Task { await remove(account) } }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .settingsActionTint(theme)
        .help("More account actions")
        .accessibilityLabel("More account actions")
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func loginControl(_ account: ServerHarnessAccount) -> some View {
    if methods.count > 1 {
      Menu("Sign In") {
        ForEach(methods) { method in
          Button(method.name) { selectLoginMethod(method, for: account) }
        }
      }
      .settingsActionTint(theme)
    } else {
      Button(methods.first?.name ?? "Sign In") {
        if let method = methods.first {
          selectLoginMethod(method, for: account)
        } else {
          Task { await login(account, methodId: nil) }
        }
      }
      .settingsActionTint(theme)
    }
  }

  private func addAccountControl(_ title: String) -> some View {
    HarnessAddAccountControl(title: title, methods: methods) { await addAccount(method: $0) }
  }

  private var authenticationTitle: String {
    harness.auth?.supportsMultipleAccounts == true ? "\(harness.name) Accounts" : "\(harness.name) Setup"
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

extension HarnessAuthenticationView {
  private func load() async {
    methods = supportedLoginMethods(harness.auth?.loginMethods ?? [])
    guard loginStep == nil else { return }
    await model.load {
      try await client.listHarnessAccounts(harnessId: harness.id)
        .filter { $0.id != draftAccount?.id }
    }
    await openRequestedSignIn()
  }

  private func openRequestedSignIn() async {
    guard signInRequest != nil, !didOpenSignInRequest, model.hasLoaded, model.errorMessage == nil else { return }
    didOpenSignInRequest = true
    if methods.count > 1 {
      choosesSignInMethod = true
    } else {
      await beginSignIn(method: methods.first)
    }
  }

  private func beginSignIn(method: ServerHarnessAuthMethod?) async {
    if let account = model.accountForSignIn {
      if let method { selectLoginMethod(method, for: account) } else { await login(account, methodId: nil) }
    } else {
      await addAccount(method: method)
    }
  }

  private func addAccount(method: ServerHarnessAuthMethod?) async {
    if model.accounts.isEmpty, let account = model.emptyDefaultAccount {
      if let method { selectLoginMethod(method, for: account) } else { await login(account, methodId: nil) }
      return
    }
    await model.perform("Starting sign-in…") {
      let account: ServerHarnessAccount
      if let draftAccount {
        account = draftAccount
      } else {
        account = try await client.createHarnessAccount(harnessId: harness.id, label: nil)
      }
      draftAccount = account
      if let method, method.kind == "apiKey" {
        loginStep = .apiKey(account: account, method: method)
      } else {
        try await startLogin(account, methodId: method?.id)
      }
    }
    if loginStep == nil { await discardDraft() }
  }

  private func activate(_ account: ServerHarnessAccount) async {
    if await model.perform(
      "Switching account…", accountId: account.id,
      optimistic: { accounts in
        accounts.map {
          var row = $0; row.isActive = row.id == account.id; return row
        }
      },
      action: {
        model.accounts = try await client.activateHarnessAccount(harnessId: harness.id, accountId: account.id)
      })
    {
      await refreshHarness()
    }
  }

  private func logout(_ account: ServerHarnessAccount) async {
    if await model.perform(
      "Signing out…", accountId: account.id,
      action: {
        let updated = try await client.logoutHarnessAccount(harnessId: harness.id, accountId: account.id)
        if isShared, ["claude-code", "codex"].contains(harness.id) {
          model.accounts.removeAll { $0.id == account.id }
        } else if let index = model.accounts.firstIndex(where: { $0.id == account.id }) {
          model.accounts[index] = updated
        }
      })
    {
      await load(); await refreshHarness()
    }
  }

  private func remove(_ account: ServerHarnessAccount) async {
    if await model.perform(
      "Removing account…", accountId: account.id,
      optimistic: { $0.filter { $0.id != account.id } },
      action: {
        try await client.removeHarnessAccount(harnessId: harness.id, accountId: account.id)
      })
    {
      await load(); await refreshHarness()
    }
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
        draftAccount = nil
        await finishAuthentication(accountId: flow.accountId)
        loginStep = nil
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
        draftAccount = nil
        await finishAuthentication(accountId: account.id)
        loginStep = nil
      }
      return nil
    } catch {
      return serverErrorMessage(error)
    }
  }

  private func login(_ account: ServerHarnessAccount, methodId: String?) async {
    await model.perform("Starting sign-in…", accountId: account.id) {
      try await startLogin(account, methodId: methodId)
    }
  }

  private func startLogin(_ account: ServerHarnessAccount, methodId: String?) async throws {
    let next = try await client.loginHarnessAccount(
      harnessId: harness.id, accountId: account.id, methodId: methodId, apiKey: nil)
    flow = next.kind == "complete" ? nil : next
    if next.kind == "complete" {
      draftAccount = nil
      await finishAuthentication(accountId: account.id)
      return
    }
    loginStep = .flow(next)
    if next.kind != "deviceCode", let value = next.url ?? next.verificationUrl, let url = URL(string: value) {
      NSWorkspace.shared.open(url)
    }
    pollingTask?.cancel()
    pollingTask = Task { await poll(accountId: account.id) }
  }

  private func poll(accountId: String) async {
    for _ in 0..<300 where !Task.isCancelled && flow != nil {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, flow != nil else { return }
      guard let account = try? await client.probeHarnessAccount(harnessId: harness.id, accountId: accountId)
      else { continue }
      guard !Task.isCancelled, flow != nil else { return }
      if account.authState == "authenticated" || account.authState == "notRequired" {
        flow = nil
        draftAccount = nil
        await finishAuthentication(accountId: accountId)
        loginStep = nil
        return
      }
      if account.authState == "error" {
        // Friendly text only — `detail` carries the probe's technical
        // cause (up to a crashed CLI's stderr) and never reaches the UI.
        let message = "Couldn't verify sign-in."
        pollingTask = nil
        await cancelFlow()
        loginStep = nil
        await load()
        model.errorMessage = message
        return
      }
    }
  }

  private func finishAuthentication(accountId: String) async {
    choosesSignInMethod = false
    if let activated = try? await client.activateHarnessAccount(
      harnessId: harness.id,
      accountId: accountId
    ) {
      model.accounts = activated
    } else {
      model.accounts = (try? await client.listHarnessAccounts(harnessId: harness.id)) ?? model.accounts
    }
    await refreshHarness()
  }

  private func cancelFlow() async {
    pollingTask?.cancel()
    pollingTask = nil
    guard flow != nil || draftAccount != nil else { return }
    await model.perform("Canceling sign-in…") {
      if let current = flow {
        flow = nil
        try await client.cancelHarnessLogin(
          harnessId: harness.id, accountId: current.accountId, flowId: current.id)
      }
      await discardDraft()
    }
  }

  private func discardDraft() async {
    guard let account = draftAccount else { return }
    do {
      let current = try await client.probeHarnessAccount(harnessId: harness.id, accountId: account.id)
      if current.authState == "unauthenticated" || current.authState == "checking" {
        try await client.removeHarnessAccount(harnessId: harness.id, accountId: account.id)
      }
      draftAccount = nil
    } catch { model.errorMessage = serverErrorMessage(error) }
  }

  private func refreshHarness() async {
    if isShared { return }
    if let updated = try? await environment.refreshHarnessAuthentication(
      harnessId: harness.id, onServer: scopedServerId)
    {
      methods = supportedLoginMethods(updated.auth?.loginMethods ?? methods)
      onChange(updated)
    }
  }

  private func supportedLoginMethods(
    _ candidates: [ServerHarnessAuthMethod]
  ) -> [ServerHarnessAuthMethod] {
    guard harness.id == "codex", scopedServerId != CodevisorMachine.local.id else {
      return candidates
    }
    return candidates.filter { $0.id != "chatgpt" }
  }

}
