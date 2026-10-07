import CodevisorCore
import SwiftUI

/// The providers a harness signs in to, and their credentials: the same
/// pane, states and wording for every such harness (Pi, and each OpenCode
/// profile), on macOS and iOS.
public struct HarnessProvidersPane: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.sharedHarnessAccounts) private var isShared

  @Bindable private var accounts: HarnessProviderAccounts
  private let harness: ServerHarness
  /// Shared credentials this machine also uses, listed read-only.
  private let inherited: HarnessSharedCredentials?
  /// Where a removed credential is removed from, for the confirmation.
  private let scope: String
  private let request: HarnessMachineSignIn?
  private let onChange: () async -> Void

  @State private var signIn: SignInRequest?
  @State private var pendingRemoval: HarnessProvider?
  @State private var didOpenRequest = false
  #if os(macOS)
    @State private var selectedProviderId: String?
  #endif

  public init(
    accounts: HarnessProviderAccounts, harness: ServerHarness, inherited: HarnessSharedCredentials?,
    scope: String, request: HarnessMachineSignIn? = nil, onChange: @escaping () async -> Void = {}
  ) {
    self.accounts = accounts
    self.harness = harness
    self.inherited = inherited
    self.scope = scope
    self.request = request
    self.onChange = onChange
  }

  private var hasInherited: Bool {
    guard let inherited else { return false }
    return (try? inherited.credentials(from: inherited.content(in: environment.configSync)).isEmpty) == false
  }

  private var canAdd: Bool { !accounts.available.isEmpty && !accounts.isWorking }

  public var body: some View {
    Group {
      switch accounts.load {
      case .loading:
        SheetLoadingView("Loading providers…")
      case .failed(let message):
        ContentUnavailableView {
          Label("Couldn’t Load Providers", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Retry") { Task { await accounts.reload() } }
        }
      case .loaded:
        if accounts.configured.isEmpty && !hasInherited {
          HarnessSignInInvitation(harnessId: harness.id, harnessName: harness.name, errorMessage: inlineError) {
            Button("Sign In", systemImage: "plus") { signIn = SignInRequest(providerId: nil) }
              .disabled(!canAdd)
          }
        } else {
          providerList
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #if os(macOS)
      .harnessWorking(accounts.workingLabel)
      .alert(harness.name, isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(accounts.errorMessage ?? "")
      }
    #else
      .sheetStatus(accounts.workingLabel)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if !accounts.configured.isEmpty || hasInherited {
            Button("Add Provider", systemImage: "plus") { signIn = SignInRequest(providerId: nil) }
            .labelStyle(.iconOnly)
            .disabled(!canAdd)
          }
        }
      }
    #endif
    .task {
      await accounts.reload()
      guard !didOpenRequest, let request, accounts.load == .loaded else { return }
      didOpenRequest = true
      signIn = SignInRequest(providerId: request.providerId)
    }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await accounts.reload() } }
    }
    .sheet(item: $signIn) { request in
      HarnessProviderSignInSheet(accounts: accounts, providerId: request.providerId) {
        await accounts.reload()
        await onChange()
      }
    }
    .alert("Remove Credential?", isPresented: removalIsPresented, presenting: pendingRemoval) { provider in
      Button("Remove", role: .destructive) {
        Task {
          await accounts.remove(provider)
          await onChange()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { provider in
      Text("Removes \(provider.name) from \(scope).")
    }
  }

  @ViewBuilder
  private var providerList: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        List(selection: $selectedProviderId) { providerSection }
          .listStyle(.inset)
        Divider()
        // The table's own +/− controls, as on the profile list beside it.
        HStack(spacing: 10) {
          Button {
            signIn = SignInRequest(providerId: nil)
          } label: {
            Image(systemName: "plus")
          }
          .disabled(!canAdd)
          .help("Add Provider")
          .accessibilityLabel("Add Provider")

          Button {
            pendingRemoval = accounts.configured.first { $0.id == selectedProviderId }
          } label: {
            Image(systemName: "minus")
          }
          .disabled(selectedProviderId == nil || accounts.isWorking)
          .help("Remove Credential")
          .accessibilityLabel("Remove Credential")

          Spacer()
        }
        .buttonStyle(.borderless)
        .settingsActionTint(theme)
        .padding(10)
      }
      .onChange(of: accounts.configured.map(\.id)) { _, ids in
        if let selectedProviderId, !ids.contains(selectedProviderId) { self.selectedProviderId = nil }
      }
    #else
      List {
        if let inlineError {
          Section {
            Label(inlineError, systemImage: "exclamationmark.triangle").foregroundStyle(theme.statusError)
          }
        }
        providerSection
      }
    #endif
  }

  private var providerSection: some View {
    Section("Providers") {
      if let inherited {
        HarnessSharedAccountRows(source: inherited, excludingProviderIds: Set(accounts.configured.map(\.id)))
      }
      ForEach(accounts.configured) { provider in
        row(provider)
      }
    }
  }

  @ViewBuilder
  private func row(_ provider: HarnessProvider) -> some View {
    let replaceable = !provider.methods.isEmpty
    #if os(macOS)
      HarnessProviderRow(provider: provider)
        .tag(provider.id)
        .contextMenu {
          Button("Replace Credential…") { signIn = SignInRequest(providerId: provider.id) }
            .disabled(!replaceable || accounts.isWorking)
          Button("Remove Credential…", role: .destructive) { pendingRemoval = provider }
            .disabled(accounts.isWorking)
        }
    #else
      Button {
        signIn = SignInRequest(providerId: provider.id)
      } label: {
        HStack {
          HarnessProviderRow(provider: provider)
          Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .disabled(!replaceable || accounts.isWorking)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = provider }
          .labelStyle(.iconOnly)
      }
    #endif
  }

  /// iOS shows failures in place; macOS raises them as an alert.
  private var inlineError: String? {
    #if os(iOS)
      accounts.errorMessage
    #else
      nil
    #endif
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { accounts.errorMessage != nil }, set: { if !$0 { accounts.errorMessage = nil } })
  }

  private var removalIsPresented: Binding<Bool> {
    Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
  }
}

private struct SignInRequest: Identifiable {
  let id = UUID()
  let providerId: String?
}

/// One configured provider: its name, and what kind of credential it has.
struct HarnessProviderRow: View {
  @Environment(\.theme) private var theme
  let provider: HarnessProvider

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "key.fill")
        .foregroundStyle(theme.textSecondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(provider.name).foregroundStyle(Color.primary)
        Text(provider.credential.map(Self.description) ?? "")
          #if os(macOS)
            .font(.callout)
          #else
            .font(.footnote)
          #endif
          .foregroundStyle(theme.textSecondary)
      }
      Spacer()
    }
    .padding(.vertical, 3)
  }

  static func description(_ credential: HarnessProvider.Credential) -> String {
    switch credential {
    case .providerAccount: "Provider Account"
    case .apiKey: "API Key"
    case .external: "External Credential"
    }
  }
}
