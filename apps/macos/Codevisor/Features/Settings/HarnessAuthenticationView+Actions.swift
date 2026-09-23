import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Actions

extension HarnessAuthenticationView {
  func load() async {
    methods = supportedLoginMethods(harness.auth?.loginMethods ?? [])
    guard loginStep == nil else { return }
    await model.load {
      try await client.listHarnessAccounts(harnessId: harness.id)
        .filter { $0.id != draftAccount?.id }
    }
    await openRequestedSignIn()
  }

  func openRequestedSignIn() async {
    guard signInRequest != nil, !didOpenSignInRequest, model.hasLoaded, model.errorMessage == nil else { return }
    didOpenSignInRequest = true
    if methods.count > 1 {
      choosesSignInMethod = true
    } else {
      await beginSignIn(method: methods.first)
    }
  }

  func beginSignIn(method: ServerHarnessAuthMethod?) async {
    if let account = model.accountForSignIn {
      if let method { selectLoginMethod(method, for: account) } else { await login(account, methodId: nil) }
    } else {
      await addAccount(method: method)
    }
  }

  func addAccount(method: ServerHarnessAuthMethod?) async {
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

  func activate(_ account: ServerHarnessAccount) async {
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

  func logout(_ account: ServerHarnessAccount) async {
    if await model.perform(
      "Signing out…", accountId: account.id,
      action: {
        let updated = try await client.logoutHarnessAccount(harnessId: harness.id, accountId: account.id)
        if isShared, HarnessRegistry.descriptor(for: harness.id).supportsMultipleAccounts {
          model.accounts.removeAll { $0.id == account.id }
        } else if let index = model.accounts.firstIndex(where: { $0.id == account.id }) {
          model.accounts[index] = updated
        }
      })
    {
      await load(); await refreshHarness()
    }
  }

  func remove(_ account: ServerHarnessAccount) async {
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

  func selectLoginMethod(_ method: ServerHarnessAuthMethod, for account: ServerHarnessAccount) {
    // Fleet credentials (OpenCode, Pi) sign in through a machine; fleet
    // account rows sign in right here.
    if isShared, !HarnessRegistry.descriptor(for: harness.id).usesFleetAccountRows, method.kind != "apiKey" {
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
  func submitPastedCode(_ code: String) async -> String? {
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
  func submitApiKey(
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

  func login(_ account: ServerHarnessAccount, methodId: String?) async {
    await model.perform("Starting sign-in…", accountId: account.id) {
      try await startLogin(account, methodId: methodId)
    }
  }

  func startLogin(_ account: ServerHarnessAccount, methodId: String?) async throws {
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

  func poll(accountId: String) async {
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

  func finishAuthentication(accountId: String) async {
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

  func cancelFlow() async {
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

  func discardDraft() async {
    guard let account = draftAccount else { return }
    do {
      let current = try await client.probeHarnessAccount(harnessId: harness.id, accountId: account.id)
      if current.authState == "unauthenticated" || current.authState == "checking" {
        try await client.removeHarnessAccount(harnessId: harness.id, accountId: account.id)
      }
      draftAccount = nil
    } catch { model.errorMessage = serverErrorMessage(error) }
  }

  func refreshHarness() async {
    if isShared { return }
    if let updated = try? await environment.refreshHarnessAuthentication(
      harnessId: harness.id, onServer: scopedServerId)
    {
      methods = supportedLoginMethods(updated.auth?.loginMethods ?? methods)
      onChange(updated)
    }
  }

  func supportedLoginMethods(
    _ candidates: [ServerHarnessAuthMethod]
  ) -> [ServerHarnessAuthMethod] {
    guard harness.id == "codex", scopedServerId != CodevisorMachine.local.id else {
      return candidates
    }
    return candidates.filter { $0.id != "chatgpt" }
  }

}
