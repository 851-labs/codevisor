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
  @Environment(AppEnvironment.self) var environment
  @Environment(\.sharedHarnessAccounts) var isShared
  @Environment(\.harnessMachineSignIn) var machineSignIn
  @Environment(\.openURL) var openURL
  @Environment(\.dismiss) var dismiss
  @Environment(\.theme) var theme

  let serverId: String
  @State var harness: ServerHarness
  var onAuthenticated: () -> Void = {}
  var signInRequest: HarnessMachineSignIn?

  @State var model = HarnessAccountListModel()
  @State var didOpenSignInRequest = false
  @State var choosesSignInMethod = false
  @State var draftAccount: ServerHarnessAccount?
  @State var pollingTask: Task<Void, Never>?
  @State var methods: [ServerHarnessAuthMethod] = []
  @State var flow: ServerHarnessAuthFlow?
  @State var loginStep: HarnessLoginStep?
  @State var pendingAccountId: String?

  var isAccountPicker: Bool { harness.auth?.supportsMultipleAccounts == true }
  var selectedAccountId: String? { pendingAccountId ?? model.accounts.first(where: \.isActive)?.id }
  var canConfirmSelection: Bool {
    model.accounts.contains { $0.id == selectedAccountId && canSelect($0) }
  }

  var client: HarnessAccountsStore {
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
      .sheetStatus(model.operation)
      .navigationBarBackButtonHidden(isAccountPicker)
      .interactiveDismissDisabled(model.isWorking)
      .toolbar {
        if isAccountPicker {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark", role: .close) { dismiss() }
              .labelStyle(.iconOnly).disabled(model.isWorking)
          }
          ToolbarItem(placement: .topBarTrailing) {
            if model.hasLoaded, !model.accounts.isEmpty, !choosesSignInMethod {
              addAccountControl("Add Account")
                .labelStyle(.iconOnly)
                .disabled(model.isWorking)
            }
          }
          ToolbarSpacer(.fixed, placement: .topBarTrailing)
          if !model.accounts.isEmpty, !choosesSignInMethod {
            // Text, not a bare checkmark: the verb is what makes this
            // legible. Becomes a spinner while the switch is in flight.
            SheetConfirmToolbarItem(
              "Use", isEnabled: canConfirmSelection && !model.isWorking
            ) {
              Task { await confirmSelection() }
            }
          }
        } else {
          HarnessAccountsCloseToolbar()
        }
      }
      .sheet(item: $loginStep, onDismiss: { Task { await cancelFlow() } }) { step in
        HarnessLoginStepScreen(
          harness: harness,
          step: step,
          submitCode: { code in await submitPastedCode(code) },
          submitApiKey: { account, method, key in
            await submitApiKey(account: account, method: method, key: key)
          },
          cancel: { loginStep = nil }
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
        pollingTask?.cancel()
        Task { await cancelFlow() }
      }
  }

  // MARK: - Layout

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
            .foregroundStyle(theme.statusError)
        }
      }

      Section(accountSectionTitle) {
        if !isShared, !HarnessRegistry.descriptor(for: harness.id).usesFleetAccountRows,
          let source = HarnessSharedCredentials(rawValue: harness.id)
        {
          HarnessSharedAccountRows(source: source)
        }
        ForEach(model.accounts) { account in accountRow(account) }
      }

    }.disabled(model.isWorking)
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
            .foregroundStyle(theme.textSecondary)
            .lineLimit(2)
        }
      }
      Spacer()
      // Per-row progress for a per-row operation: the model already tracks
      // which account is busy, and a trailing spinner is the native idiom.
      if account.id == model.workingAccountId {
        ProgressView().controlSize(.small)
      } else if !canSelect(account), account.canLogin {
        loginControl(account)
      }
    }
    .contentShape(Rectangle())
  }

  func canSelect(_ account: ServerHarnessAccount) -> Bool {
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

  private func addAccountControl(_ title: String) -> some View {
    HarnessAddAccountControl(title: title, methods: methods) { await addAccount(method: $0) }
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
