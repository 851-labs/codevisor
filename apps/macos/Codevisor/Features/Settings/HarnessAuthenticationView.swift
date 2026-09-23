import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct HarnessAuthenticationView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.sharedHarnessAccounts) var isShared
  @Environment(\.harnessMachineSignIn) var machineSignIn
  @Environment(\.settingsMachineId) var settingsMachineId

  /// The machine this view operates on — pinned by the machine-scoped
  /// Settings page that presented it, else the app's selected machine
  /// (onboarding, previews).
  var scopedServerId: String {
    settingsMachineId ?? environment.defaultComposerServerId
  }

  var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: scopedServerId, isShared: isShared)
  }

  @Environment(\.dismiss) var dismiss
  @Environment(\.theme) var theme

  let harness: ServerHarness
  var onChange: (ServerHarness) -> Void
  /// Settings/onboarding render this view standalone and want its own
  /// title and Done footer. The composer's sign-in sheet brings its own
  /// chrome (with machine context) and turns this off.
  var showsHeader = true
  var signInRequest: HarnessMachineSignIn?

  @State var model = HarnessAccountListModel()
  @State var didOpenSignInRequest = false
  @State var choosesSignInMethod = false
  @State var draftAccount: ServerHarnessAccount?
  @State var pollingTask: Task<Void, Never>?
  @State var methods: [ServerHarnessAuthMethod] = []
  @State var flow: ServerHarnessAuthFlow?
  /// The focused modal step a sign-in attempt runs in.
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
              .settingsActionTint(theme)
              .keyboardShortcut(.defaultAction)
              .disabled(model.isWorking)
          }
        }
        .sheetSize(.list)
        .themedSurface(.sheet)
      } else {
        accountsForm
      }
    }
    .interactiveDismissDisabled(model.isWorking)
    .task { await load() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await load() } }
    }
    // Each sign-in attempt is one focused task in its own sheet. Pushing it
    // onto the host's stack was tried and reverted — the transition runs
    // inside AppKit's layout pass, where a model mutation makes AppKit raise.
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
            .foregroundStyle(theme.statusError)
        }
        .listRowBackground(theme.formRowBackground)
      }
      Section {
        if !isShared, !HarnessRegistry.descriptor(for: harness.id).usesFleetAccountRows,
          let source = HarnessSharedCredentials(rawValue: harness.id)
        {
          HarnessSharedAccountRows(source: source)
        }
        ForEach(model.accounts) { account in accountRow(account) }
        // A trailing row, not a Section footer: footers are for explanatory
        // text, render small and secondary (hence the `.font(.body)` this
        // replaces), and sit outside the expected keyboard order.
        if harness.auth?.supportsMultipleAccounts == true {
          addAccountControl("Add Account")
            // Plain, so it carries the same weight as the account rows above
            // it and as the "Add Provider…" row in the OpenCode and Pi
            // sheets. A bordered button here would make one add-affordance
            // in the family look unlike the other two.
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .settingsActionTint(theme)
            .disabled(model.isWorking)
        }
      }
      .listRowBackground(theme.formRowBackground)
    }
    .formStyle(.grouped)
    .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
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
            Text(scope == "machine" ? "Override" : "Shared").font(.caption).foregroundStyle(theme.textSecondary)
          }
        }
        if let status = accountStatus(account) {
          Text(status)
            .font(.callout)
            .foregroundStyle(theme.textSecondary)
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
          Label("More account actions", systemImage: "ellipsis.circle")
        }
        // An ellipsis glyph already means "more actions"; a disclosure
        // chevron beside it is a second, redundant affordance. Matches
        // HarnessSettingsRow, which is the same control in the list behind
        // this sheet.
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .settingsActionTint(theme)
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
