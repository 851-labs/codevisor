import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct HarnessAuthenticationView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.sharedHarnessAccounts) var isShared
  @Environment(\.harnessMachineSignIn) var machineSignIn
  @Environment(\.settingsMachineId) var settingsMachineId

  var scopedServerId: String {
    settingsMachineId ?? environment.defaultComposerServerId
  }

  var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: scopedServerId, isShared: isShared)
  }

  @Environment(\.dismiss) var dismiss

  let harness: ServerHarness
  var onChange: (ServerHarness) -> Void
  var showsHeader = true
  var signInRequest: HarnessMachineSignIn?

  @State var model = HarnessAccountListModel()
  @State var didOpenSignInRequest = false
  @State var choosesSignInMethod = false
  @State var draftAccount: ServerHarnessAccount?
  @State var pollingTask: Task<Void, Never>?
  @State var methods: [ServerHarnessAuthMethod] = []
  @State var flow: ServerHarnessAuthFlow?
  @State var loginStep: HarnessLoginStep?

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
          accountsForm
            .navigationTitle(authenticationTitle)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter(status: model.operation) {
            Button("Done") { dismiss() }
              .keyboardShortcut(.defaultAction)
              .disabled(model.isWorking)
          }
        }
        .sheetSize(.list)
      } else {
        accountsForm
      }
    }
    .interactiveDismissDisabled(model.isWorking)
    .task { await load() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await load() } }
    }
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
            .foregroundStyle(.red)
        }
      }
      Section {
        if !isShared, !HarnessRegistry.descriptor(for: harness.id).usesFleetAccountRows,
          let source = HarnessSharedCredentials(rawValue: harness.id)
        {
          HarnessSharedAccountRows(source: source)
        }
        ForEach(model.accounts) { account in accountRow(account) }
        if harness.auth?.supportsMultipleAccounts == true {
          addAccountControl("Add Account")
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
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
        .foregroundStyle(account.isActive ? Color.primary : Color.secondary)
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
        }
        if account.canLogout {
          Button("Sign Out") { Task { await logout(account) } }
        }
      } else if account.canLogin {
        loginControl(account)
      }
      if account.profileKind == "managed" {
        Menu {
          Button("Remove Account", role: .destructive) { Task { await remove(account) } }
        } label: {
          Label("More account actions", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More account actions")
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
    } else {
      Button(methods.first?.name ?? "Sign In") {
        if let method = methods.first {
          selectLoginMethod(method, for: account)
        } else {
          Task { await login(account, methodId: nil) }
        }
      }
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
    case "error": return "Something went wrong starting the CLI"
    default: return "Not signed in"
    }
  }
}
