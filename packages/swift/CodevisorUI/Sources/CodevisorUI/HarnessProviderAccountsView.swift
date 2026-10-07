import CodevisorCore
import SwiftUI

/// The providers of a harness that signs in per provider: Pi's, or one
/// OpenCode profile's. Shared settings and a machine's own accounts use the
/// same view; a machine's own list adds the shared credentials it inherits.
public struct HarnessProviderAccountsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.sharedHarnessAccounts) private var isShared

  private let harness: ServerHarness
  private let machineId: String
  private let profile: ServerHarnessAccount?
  private let request: HarnessMachineSignIn?
  private let onChange: () async -> Void
  @State private var accounts: HarnessProviderAccounts?

  /// - Parameter profile: the OpenCode profile whose providers these are.
  public init(
    harness: ServerHarness, machineId: String, profile: ServerHarnessAccount? = nil,
    request: HarnessMachineSignIn? = nil, onChange: @escaping () async -> Void = {}
  ) {
    self.harness = harness
    self.machineId = machineId
    self.profile = profile
    self.request = request
    self.onChange = onChange
  }

  /// A machine's own default credentials sit beside the shared ones.
  private var isMachineDefault: Bool { !isShared && (profile == nil || profile?.profileKind == "default") }

  private var inherited: HarnessSharedCredentials? {
    guard isMachineDefault else { return nil }
    return profile == nil ? .pi : .opencode
  }

  private var scope: String {
    if isShared { return "your shared providers" }
    return isMachineDefault ? "this machine" : "this profile"
  }

  public var body: some View {
    Group {
      if let accounts {
        HarnessProvidersPane(
          accounts: accounts, harness: harness, inherited: inherited, scope: scope, request: request,
          onChange: onChange)
      } else {
        SheetLoadingView("Loading providers…")
      }
    }
    .onAppear {
      guard accounts == nil else { return }
      let store = HarnessAccountsStore(environment: environment, machineId: machineId, isShared: isShared)
      let backend: any HarnessProviderBackend =
        if let profile {
          OpenCodeProviderBackend(store: store, accountId: profile.id)
        } else {
          PiProviderBackend(store: store)
        }
      accounts = HarnessProviderAccounts(backend: backend, providerAccountsOnly: isMachineDefault)
    }
  }
}
