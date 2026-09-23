import CodevisorCore
import SwiftUI

/// The same provider list is used for shared settings and a machine's accounts.
public struct PiProviderAccounts: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.harnessMachineSignIn) private var machineSignIn
  private let machineId: String
  private let harness: ServerHarness
  private let request: HarnessMachineSignIn?
  private let onChange: (ServerHarness) -> Void
  @State private var providers: [ServerPiAuthProvider] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var setup: HarnessMachineSignIn?
  @State private var pendingMachineSignIn: HarnessMachineSignIn?
  @State private var didOpenRequest = false
  @State private var pendingRemoval: ServerPiAuthProvider?

  public init(
    machineId: String, harness: ServerHarness, request: HarnessMachineSignIn? = nil,
    onChange: @escaping (ServerHarness) -> Void = { _ in }
  ) {
    self.machineId = machineId
    self.harness = harness
    self.request = request
    self.onChange = onChange
  }

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: machineId, isShared: isShared)
  }
  private var configured: [ServerPiAuthProvider] {
    providers.filter { $0.credentialType != nil && (isShared || $0.credentialType == "oauth") }
  }
  private var hasInherited: Bool {
    !isShared
      && ((try? HarnessSharedCredentials.pi.credentials(
        from: HarnessSharedCredentials.pi.content(in: environment.configSync)
      ).isEmpty) == false)
  }

  public var body: some View {
    Group {
      if isLoading && providers.isEmpty {
        SheetLoadingView("Loading providers…")
      } else if providers.isEmpty, let errorMessage {
        ContentUnavailableView {
          Label("Couldn't Load Accounts", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Retry") { Task { await load() } }
        }
      } else if configured.isEmpty && !hasInherited {
        HarnessSignInInvitation(harnessId: harness.id, harnessName: harness.name, errorMessage: errorMessage) {
          Button("Sign In", systemImage: "plus") { setup = HarnessMachineSignIn() }
            .disabled(isLoading)
        }
      } else {
        Form {
          if let errorMessage {
            Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(theme.statusError) }
          }
          Section {
            if !isShared { HarnessSharedAccountRows(source: .pi, excludingProviderIds: Set(configured.map(\.id))) }
            ForEach(configured) { provider in
              providerRow(provider)
            }
            // A trailing row, matching the accounts sheet and the OpenCode
            // provider list. This replaces an empty Section whose only job
            // was to host a footer button — which rendered small and
            // secondary, hence the `.font(.body)` override it needed.
            #if os(macOS)
              Button("Add Provider…", systemImage: "plus") { setup = HarnessMachineSignIn() }
                .buttonStyle(.plain)
                .disabled(isLoading)
            #endif
          }
        }
        .formStyle(.grouped)
      }
    }
    #if os(iOS)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if !configured.isEmpty || hasInherited {
            Button("Add Provider", systemImage: "plus") { setup = HarnessMachineSignIn() }
            .labelStyle(.iconOnly).disabled(isLoading)
          }
        }
        HarnessAccountsCloseToolbar()
      }
    #endif
    .task {
      await load()
      if !didOpenRequest, let request {
        didOpenRequest = true
        setup = request
      }
    }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      Task { await load() }
    }
    .sheet(
      item: $setup,
      onDismiss: {
        if let pendingMachineSignIn {
          self.pendingMachineSignIn = nil
          machineSignIn?(pendingMachineSignIn)
        }
      }
    ) { request in
      PiProviderSetupSheet(machineId: machineId, providers: providers, initialProviderId: request.providerId) {
        Task {
          await load(); await refresh()
        }
      }
      .environment(
        \.harnessMachineSignIn,
        {
          pendingMachineSignIn = $0; setup = nil
        })
    }
    .alert(
      "Remove Credential?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
      ), presenting: pendingRemoval
    ) { provider in
      Button("Remove", role: .destructive) { Task { await remove(provider) } }
      Button("Cancel", role: .cancel) {}
    } message: { provider in
      Text(
        isShared
          ? "Removes \(provider.name) from your shared providers." : "Removes \(provider.name) from this machine.")
    }
  }

  private func providerRow(_ provider: ServerPiAuthProvider) -> some View {
    HStack {
      Label(provider.name, systemImage: provider.credentialType == "oauth" ? "person.crop.circle" : "key")
      Spacer()
      #if os(macOS)
        Menu {
          Button("Replace Credential…") { setup = HarnessMachineSignIn(providerId: provider.id) }
          Button("Remove Credential…", role: .destructive) { pendingRemoval = provider }
        } label: {
          Label("Provider Actions", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      #endif
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Replace Credential…") { setup = HarnessMachineSignIn(providerId: provider.id) }
      Button("Remove Credential…", role: .destructive) { pendingRemoval = provider }
    }
    #if os(iOS)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = provider }.labelStyle(.iconOnly)
        Button("Replace Credential", systemImage: "pencil") { setup = HarnessMachineSignIn(providerId: provider.id) }
        .labelStyle(.iconOnly).tint(.blue)
      }
    #endif
  }

  private func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      providers = try await client.listPiAuthProviders().map { provider in
        var item = provider
        item.methods = isShared ? provider.methods : provider.methods.filter { $0 == "oauth" }
        return item
      }.filter { !$0.methods.isEmpty }
      errorMessage = nil
    } catch { errorMessage = serverErrorMessage(error) }
  }
  private func remove(_ provider: ServerPiAuthProvider) async {
    do { try await client.removePiAuthProvider(id: provider.id); await load(); await refresh() } catch {
      errorMessage = serverErrorMessage(error)
    }
  }
  private func refresh() async {
    guard !isShared else { return }
    if let updated = try? await environment.refreshHarnessAuthentication(harnessId: harness.id, onServer: machineId) {
      onChange(updated)
    }
  }
}
