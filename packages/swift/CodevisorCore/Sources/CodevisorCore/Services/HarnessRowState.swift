import ACPKit
import Foundation

/// List rows read cached facts. Opening a list never probes an account.
public struct HarnessRowState: Equatable, Sendable {
  public var status: String?
  public var needsSignIn: Bool
  public var isBusy: Bool
  public var supportsAccounts: Bool

  public var showsAccounts: Bool { supportsAccounts && !needsSignIn }

  public init(status: String? = nil, needsSignIn: Bool = false, isBusy: Bool = false, supportsAccounts: Bool = true) {
    self.status = status
    self.needsSignIn = needsSignIn
    self.isBusy = isBusy
    self.supportsAccounts = supportsAccounts
  }

  public static func machine(_ harness: ServerHarness) -> Self {
    let supportsAccounts = harness.auth != nil && harness.auth?.resolvedState != .notRequired
    switch harness.lifecycle?.resolvedPhase {
    case .installing: return .init(status: "Installing…", isBusy: true, supportsAccounts: supportsAccounts)
    case .uninstalling: return .init(status: "Uninstalling…", isBusy: true, supportsAccounts: supportsAccounts)
    case .updating: return .init(status: "Updating…", isBusy: true, supportsAccounts: supportsAccounts)
    case .pendingUpdate: return .init(status: "Update queued", supportsAccounts: supportsAccounts)
    case .failed: return .init(status: "Needs attention", supportsAccounts: supportsAccounts)
    default: break
    }
    guard harness.isDesiredEnabled else { return .init(supportsAccounts: supportsAccounts) }
    guard harness.isReady else { return .init(status: "Not installed", supportsAccounts: supportsAccounts) }
    switch harness.auth?.resolvedState {
    case .unauthenticated:
      let hasAccounts = harness.auth?.accounts.contains { !$0.isEmptyDefaultAccount } == true
      return hasAccounts ? .init(status: "Sign in required") : .init(needsSignIn: true)
    case .expired: return .init(status: "Sign in required")
    case .checking: return .init(status: "Checking sign-in…", supportsAccounts: supportsAccounts)
    case .error: return .init(status: "Couldn't check sign-in", supportsAccounts: supportsAccounts)
    case .unavailable: return .init(status: "Sign-in unavailable", supportsAccounts: supportsAccounts)
    default: return .init(supportsAccounts: supportsAccounts)
    }
  }

  /// Whether accounts for this harness live in the fleet (shared account
  /// rows or shared credentials) rather than on each machine.
  public static func sharesFleetAccounts(harnessId: String) -> Bool {
    HarnessRegistry.descriptor(for: harnessId).sharesFleetAccounts
  }

  /// Whether the replica holds a usable fleet-shared account for the harness.
  /// No secrets leave the replica.
  @MainActor
  public static func hasSharedAccounts(harnessId: String, sync: ConfigSync) -> Bool {
    let source = HarnessSharedCredentials(rawValue: harnessId)
    _ = sync.revisionsByNamespace["harness-shared-accounts"]
    _ = sync.revisionsByNamespace[HarnessSharedCredentials.namespace]
    let hasOAuthAccounts = sync.entries(namespace: "harness-shared-accounts").contains { entry in
      guard entry.deleted != true, entry.key.hasPrefix("shared-") || entry.key.hasPrefix("provider:"),
        case .object(let fields) = entry.value,
        fields["harnessId"] == .string(harnessId)
      else { return false }
      // Saved accounts remain manageable without credentials.
      if entry.key.hasPrefix("shared-"), fields["id"] == .string(entry.key), case .string = fields["label"] {
        return true
      }
      guard
        case .object(let credential) = fields["credential"],
        case .string(let id) = credential["id"], !id.isEmpty,
        case .string(let key) = credential["key"], !key.isEmpty
      else { return false }
      return true
    }
    if hasOAuthAccounts { return true }
    if harnessId == "opencode",
      case .string(let content) = sync.value(namespace: HarnessSharedCredentials.namespace, key: "profiles:opencode"),
      let profiles = try? JSONDecoder().decode(HarnessAccountsStore.Profiles.self, from: Data(content.utf8)),
      !profiles.profiles.isEmpty
    {
      return true
    }
    guard let source else { return false }
    // OpenCode can have credentials in any shared profile, including a
    // profile other than Default. An empty default profile is a discovery slot.
    let contents = sync.entries(namespace: HarnessSharedCredentials.namespace).compactMap { entry -> String? in
      guard entry.deleted != true,
        entry.key == source.sourceKey || (harnessId == "opencode" && entry.key.hasPrefix("opencode-profile:")),
        case .string(let value) = entry.value
      else { return nil }
      return value
    }
    return contents.contains(where: { (try? source.credentials(from: $0).isEmpty) == false })
  }

  /// Presence of shared accounts is independent of any machine's local
  /// probe result, installation, or account override.
  @MainActor
  public static func shared(harnessId: String, sync: ConfigSync, authRequired: Bool = true) -> Self {
    guard authRequired else { return .init(supportsAccounts: false) }
    if hasSharedAccounts(harnessId: harnessId, sync: sync) { return .init() }
    let usesOAuth = HarnessRegistry.descriptor(for: harnessId).fleetSignInNeedsMachine
    let source = HarnessSharedCredentials(rawValue: harnessId)
    guard usesOAuth || source != nil else {
      // Machine-bound providers retain Accounts in the menu. Their readiness
      // belongs to the machine, not to a synthetic global signed-out state.
      return .init()
    }
    guard (!usesOAuth || sync.hasSnapshot(namespace: "harness-shared-accounts")),
      (source == nil || sync.hasSnapshot(namespace: HarnessSharedCredentials.namespace))
    else { return .init() }
    return .init(needsSignIn: true)
  }
}

public extension ServerHarnessAccount {
  /// Discovery creates a default slot even when no account exists. Keep its
  /// ID for sign-in, but don't present it as an account the user configured.
  var isEmptyDefaultAccount: Bool {
    profileKind == "default" && authState == "unauthenticated"
      && email == nil && organizationId == nil && !canLogout
  }
}
