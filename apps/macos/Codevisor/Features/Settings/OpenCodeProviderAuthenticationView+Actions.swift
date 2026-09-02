import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

// MARK: - Actions

extension OpenCodeProviderAuthenticationView {
  func loadAccounts() async {
    await perform {
      let loaded = try await client.listHarnessAccounts(harnessId: "opencode")
      accounts = loaded
      if !loaded.contains(where: { $0.id == selectedAccountId }) {
        selectedAccountId = loaded.first(where: \.isActive)?.id ?? loaded.first?.id
      }
    }
  }

  func loadProviders(accountId: String) async {
    isLoadingProviders = true
    do {
      let loaded = try await client.listOpenCodeAuthProviders(accountId: accountId)
      guard selectedAccountId == accountId else { return }
      providers = loaded
      providerAccountId = accountId
      if !loaded.contains(where: { $0.id == selectedProviderId }) {
        selectedProviderId = loaded.first(where: { $0.credentialType != nil })?.id
      }
      selectDefaultMethod()
    } catch {
      guard selectedAccountId == accountId else { return }
      providers = []
      providerAccountId = accountId
      selectedProviderId = nil
      errorMessage = serverErrorMessage(error)
    }
    if selectedAccountId == accountId { isLoadingProviders = false }
  }

  func addProfile() async {
    let label = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return }
    await perform {
      let account = try await client.createHarnessAccount(harnessId: "opencode", label: label)
      accounts.append(account)
      selectedAccountId = account.id
    }
  }

  func activate(_ account: ServerHarnessAccount) async {
    await perform {
      accounts = try await client.activateHarnessAccount(harnessId: "opencode", accountId: account.id)
    }
    await refreshHarness()
  }

  func requestProfileRemoval(_ account: ServerHarnessAccount) {
    guard account.profileKind == "managed" else { return }
    profilePendingRemoval = account
    showingRemoveProfileAlert = true
  }

  func requestProfileRename(_ account: ServerHarnessAccount) {
    guard account.profileKind == "managed" else { return }
    profilePendingRename = account
    profileNameDraft = profileName(account)
    showingRenameProfile = true
  }

  func renameProfile(_ account: ServerHarnessAccount) async {
    let label = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return }
    await perform {
      let renamed = try await client.renameHarnessAccount(
        harnessId: "opencode",
        accountId: account.id,
        label: label
      )
      if let index = accounts.firstIndex(where: { $0.id == renamed.id }) {
        accounts[index] = renamed
      }
    }
    await refreshHarness()
  }

  func removeProfile(_ account: ServerHarnessAccount) async {
    await perform {
      try await client.removeHarnessAccount(harnessId: "opencode", accountId: account.id)
      accounts = try await client.listHarnessAccounts(harnessId: "opencode")
      selectedAccountId = accounts.first(where: \.isActive)?.id ?? accounts.first?.id
    }
    await refreshHarness()
  }

  func prepareProviderSignIn(_ provider: ServerOpenCodeAuthProvider? = nil) {
    let choice = provider ?? providers.first(where: { $0.credentialType == nil }) ?? providers.first
    selectedProviderId = choice?.id
    providerSearch = provider?.name ?? ""
    openedURL = nil
    selectDefaultMethod()
    showingProviderSignIn = choice != nil
  }

  func submitSelectedMethod() {
    guard let method = selectedMethod, canSubmit(method) else { return }
    Task { await beginLogin() }
  }

  func beginLogin() async {
    guard let account = selectedAccount, let provider = selectedProvider, let method = selectedMethod else {
      return
    }
    await perform {
      let next = try await client.startOpenCodeAuth(
        accountId: account.id,
        providerId: provider.id,
        methodId: method.id,
        inputs: inputs.isEmpty ? nil : inputs,
        apiKey: method.type == "api" ? apiKey : nil
      )
      await apply(next)
    }
  }

  func submitCode(_ flow: ServerOpenCodeAuthFlow) {
    let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { return }
    Task {
      await perform {
        let next = try await client.answerOpenCodeAuthFlow(id: flow.id, code: code)
        authorizationCode = ""
        await apply(next)
      }
    }
  }

  private func apply(_ next: ServerOpenCodeAuthFlow) async {
    flow = next
    if let url = next.authorization?.url, openedURL != url {
      openedURL = url
      open(url)
    }
    if next.state == "complete" {
      flow = nil
      pollingFlowId = nil
      resetInput()
      if let accountId = selectedAccountId { await loadProviders(accountId: accountId) }
      await refreshHarness()
      showingProviderSignIn = false
    } else if next.state == "error" {
      errorMessage = next.error ?? "OpenCode authentication failed."
      flow = nil
      pollingFlowId = nil
    } else if next.state == "running" {
      beginPolling(next.id)
    }
  }

  private func beginPolling(_ id: String) {
    guard pollingFlowId != id else { return }
    pollingFlowId = id
    Task {
      while !Task.isCancelled, pollingFlowId == id {
        try? await Task.sleep(for: .seconds(1))
        guard let next = try? await client.openCodeAuthFlow(id: id) else { continue }
        let pending = next.state == "running" || next.state == "waiting"
        if !pending { pollingFlowId = nil }
        await apply(next)
        if !pending { return }
      }
    }
  }

  func providerSheetDismissed() {
    cancelPendingFlow()
    providerSearch = ""
    authorizationCode = ""
  }

  func cancelPendingFlow() {
    guard let flow, flow.state == "running" || flow.state == "waiting" else { return }
    self.flow = nil
    pollingFlowId = nil
    Task { try? await client.cancelOpenCodeAuthFlow(id: flow.id) }
  }

  func remove(_ provider: ServerOpenCodeAuthProvider) async {
    guard let account = selectedAccount else { return }
    await perform {
      try await client.removeOpenCodeAuthProvider(accountId: account.id, providerId: provider.id)
      await loadProviders(accountId: account.id)
      await refreshHarness()
    }
  }

  private func refreshHarness() async {
    if let updated = try? await environment.refreshHarnessAuthentication(
      harnessId: "opencode", onServer: scopedServerId)
    {
      accounts = updated.auth?.accounts ?? accounts
      onChange(updated)
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }

  func credentialDescription(_ type: String?) -> String {
    switch type {
    case "oauth": return "Provider Account"
    case "wellknown": return "External Credential"
    default: return "API Key"
    }
  }

  func profileName(_ account: ServerHarnessAccount) -> String {
    if account.profileKind == "default" { return "Local OpenCode" }
    if account.label.hasPrefix("OpenCode profile "),
      let index = accounts.filter({ $0.profileKind == "managed" }).firstIndex(where: { $0.id == account.id })
    {
      return "Profile \(index + 1)"
    }
    return account.label
  }

  func open(_ value: String) {
    guard let url = URL(string: value) else { return }
    NSWorkspace.shared.open(url)
  }
}
