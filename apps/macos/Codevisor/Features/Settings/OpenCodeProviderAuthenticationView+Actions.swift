import CodevisorCore
import SwiftUI
import CodevisorUI

// MARK: - Actions

extension OpenCodeProviderAuthenticationView {
  func loadAccounts() async {
    await perform("Loading profiles…") {
      let loaded: [ServerHarnessAccount]
      do {
        loaded = try await client.listHarnessAccounts(harnessId: "opencode")
      } catch {
        // Nothing to show yet: the sheet explains the failure in place, with
        // a retry, rather than an alert over an empty list.
        guard profilesLoaded else {
          profilesError = serverErrorMessage(error)
          return
        }
        throw error
      }
      profilesError = nil
      profilesLoaded = true
      accounts = loaded
      if !loaded.contains(where: { $0.id == selectedAccountId }) {
        selectedAccountId =
          loaded.first(where: {
            signInRequest?.profileId == "default" ? $0.profileKind == "default" : $0.id == signInRequest?.profileId
          })?.id ?? loaded.first(where: \.isActive)?.id ?? loaded.first?.id
      }
    }
  }

  func addProfile() async {
    let label = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return }
    await perform("Adding profile…") {
      let account = try await client.createHarnessAccount(harnessId: "opencode", label: label)
      accounts.append(account)
      selectedAccountId = account.id
    }
  }

  func activate(_ account: ServerHarnessAccount) async {
    await perform("Switching profile…") {
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
    await perform("Renaming profile…") {
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
    await perform("Removing profile…") {
      try await client.removeHarnessAccount(harnessId: "opencode", accountId: account.id)
      accounts = try await client.listHarnessAccounts(harnessId: "opencode")
      selectedAccountId = accounts.first(where: \.isActive)?.id ?? accounts.first?.id
    }
    await refreshHarness()
  }

  func refreshHarness() async {
    if isShared { await loadAccounts(); return }
    if let updated = try? await environment.refreshHarnessAuthentication(
      harnessId: "opencode", onServer: scopedServerId)
    {
      accounts = updated.auth?.accounts ?? accounts
      onChange(updated)
    }
  }

  /// `label` is what the sheet's footer says while this runs. Every
  /// blocking operation names itself; none of them renders in the body.
  private func perform(_ label: String, _ operation: () async throws -> Void) async {
    workingLabel = label
    errorMessage = nil
    defer { workingLabel = nil }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }

  func profileName(_ account: ServerHarnessAccount) -> String {
    if account.profileKind == "default" { return "Default Profile" }
    if account.label.hasPrefix("OpenCode profile "),
      let index = accounts.filter({ $0.profileKind == "managed" }).firstIndex(where: { $0.id == account.id })
    {
      return "Profile \(index + 1)"
    }
    return account.label
  }
}
