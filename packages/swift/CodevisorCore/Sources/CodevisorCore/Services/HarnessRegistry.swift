import Foundation

/// What the client knows about a harness before any machine has described
/// it: its name, its symbol, and — the part every accounts screen used to
/// keep its own list for — where its sign-in lives. Screens ask here; none
/// of them carries a `["claude-code", "codex", …]` array of its own.
public struct HarnessDescriptor: Equatable, Sendable {
  /// Where a harness's accounts live.
  public enum AccountScope: Equatable, Sendable {
    /// Each machine signs in on its own; Settings opens that machine's sheet.
    case machine
    /// One fleet-wide account list kept as server-side shared account rows:
    /// one RPC lists, creates, activates and signs them in. A sign-in flow
    /// runs on whichever online machine hosts the harness.
    case fleetAccounts
    /// One fleet-wide credential document replicated through ConfigSync
    /// (per-provider API keys). `signInNeedsMachine` is true when the
    /// harness also offers OAuth grants, which need a machine to run the
    /// browser flow.
    case fleetCredentials(signInNeedsMachine: Bool)
  }

  public let id: String
  public let displayName: String
  public let symbolName: String
  public let accountScope: AccountScope
  public let supportsMultipleAccounts: Bool
  /// Credentials are nested (profiles that each contain providers), so the
  /// accounts editor is a source-list-plus-detail browser rather than a
  /// single list. Sheets read this to pick their proportions — the same
  /// reason the rest of this type exists, so that no screen has to ask
  /// "is this OpenCode?" to decide how to lay itself out.
  public let usesProviderBrowser: Bool

  public init(
    id: String, displayName: String, symbolName: String = "terminal",
    accountScope: AccountScope = .machine, supportsMultipleAccounts: Bool = false,
    usesProviderBrowser: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.symbolName = symbolName
    self.accountScope = accountScope
    self.supportsMultipleAccounts = supportsMultipleAccounts
    self.usesProviderBrowser = usesProviderBrowser
  }

  /// Accounts live in the fleet (either shape) rather than on each machine.
  public var sharesFleetAccounts: Bool { accountScope != .machine }

  /// Accounts are server-side shared rows: list and manage them over one RPC.
  public var usesFleetAccountRows: Bool { accountScope == .fleetAccounts }

  /// A fleet sign-in that has to run somewhere — the sheet needs an online
  /// machine that hosts the harness before it can offer the flow.
  public var fleetSignInNeedsMachine: Bool {
    switch accountScope {
    case .machine: false
    case .fleetAccounts: true
    case .fleetCredentials(let needsMachine): needsMachine
    }
  }
}

public enum HarnessRegistry {
  /// Built-in harnesses. Names and symbols mirror the server catalog; a
  /// machine's own report still wins when one is available, so this is the
  /// floor, never a stale ceiling.
  public static let builtin: [HarnessDescriptor] = [
    .init(
      id: "claude-code", displayName: "Claude Code", symbolName: "sparkle",
      accountScope: .fleetAccounts, supportsMultipleAccounts: true),
    .init(
      id: "codex", displayName: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
      accountScope: .fleetAccounts, supportsMultipleAccounts: true),
    .init(id: "grok-build", displayName: "Grok Build", symbolName: "x.square", accountScope: .fleetAccounts),
    .init(
      id: "opencode", displayName: "OpenCode", symbolName: "curlybraces",
      accountScope: .fleetCredentials(signInNeedsMachine: true), supportsMultipleAccounts: true,
      usesProviderBrowser: true),
    .init(id: "pi", displayName: "Pi", accountScope: .fleetCredentials(signInNeedsMachine: true)),
    .init(id: "devin", displayName: "Devin", accountScope: .fleetCredentials(signInNeedsMachine: false)),
    .init(id: "cursor", displayName: "Cursor"),
    .init(id: "gemini", displayName: "Gemini CLI", symbolName: "diamond"),
    .init(id: "goose", displayName: "goose", symbolName: "bird"),
    .init(id: "amp", displayName: "Amp", symbolName: "bolt"),
    .init(id: "blackbox", displayName: "Blackbox AI", symbolName: "shippingbox"),
    .init(id: "cortex-code", displayName: "Cortex Code", symbolName: "snowflake"),
    .init(id: "minimax-code", displayName: "MiniMax Code"),
    .init(id: "nova", displayName: "Nova"),
    .init(id: "sigit", displayName: "siGit Code"),
    .init(id: "harn", displayName: "Harn"),
    .init(id: "junie", displayName: "Junie", symbolName: "j.square"),
    .init(id: "kimchi", displayName: "Kimchi"),
    .init(id: "poolside", displayName: "Poolside", symbolName: "water.waves"),
    .init(id: "stakpak", displayName: "Stakpak", symbolName: "shippingbox"),
    .init(id: "mistral-vibe", displayName: "Mistral Vibe", symbolName: "m.square"),
    .init(id: "vtcode", displayName: "VT Code", symbolName: "v.square"),
    .init(id: "kiro", displayName: "Kiro CLI", symbolName: "k.square"),
    .init(id: "openhands", displayName: "OpenHands", symbolName: "hand.raised"),
    .init(id: "construct", displayName: "Construct", symbolName: "building.2"),
  ]

  private static let byId: [String: HarnessDescriptor] = Dictionary(
    uniqueKeysWithValues: builtin.map { ($0.id, $0) })

  /// Never nil: an unknown id (a custom ACP harness) is machine-scoped and
  /// named from its id, so no screen ever shows a raw `some-id`.
  public static func descriptor(for id: String) -> HarnessDescriptor {
    byId[id] ?? HarnessDescriptor(id: id, displayName: humanized(id))
  }

  /// The name to show for a harness, preferring what a machine reported.
  public static func displayName(for id: String, reported: String? = nil) -> String {
    if let reported, !reported.isEmpty { return reported }
    return descriptor(for: id).displayName
  }

  /// Fleet-shared harnesses whose sign-in needs an online host machine.
  public static var fleetHostedSignInIds: [String] {
    builtin.filter(\.fleetSignInNeedsMachine).map(\.id)
  }

  /// `grok-build` → `Grok Build`. Ids are lowercase and dash-separated.
  static func humanized(_ id: String) -> String {
    id.split(whereSeparator: { $0 == "-" || $0 == "_" })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}
