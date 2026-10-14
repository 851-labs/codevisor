import Foundation

public struct HarnessDescriptor: Equatable, Sendable {
  public enum AccountScope: Equatable, Sendable {
    case machine
    case fleetAccounts
    case fleetCredentials(signInNeedsMachine: Bool)
  }

  public let id: String
  public let displayName: String
  public let symbolName: String
  public let accountScope: AccountScope
  public let supportsMultipleAccounts: Bool
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

  public var sharesFleetAccounts: Bool { accountScope != .machine }

  public var usesFleetAccountRows: Bool { accountScope == .fleetAccounts }

  public var fleetSignInNeedsMachine: Bool {
    switch accountScope {
    case .machine: false
    case .fleetAccounts: true
    case .fleetCredentials(let needsMachine): needsMachine
    }
  }
}

public enum HarnessRegistry {
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
    .init(
      id: "pi", displayName: "Pi", symbolName: "function",
      accountScope: .fleetCredentials(signInNeedsMachine: true)),
    .init(
      id: "muse-code", displayName: "Muse Code", symbolName: "sparkles",
      accountScope: .fleetAccounts, supportsMultipleAccounts: true),
    .init(
      id: "antigravity", displayName: "Antigravity", symbolName: "atom",
      accountScope: .fleetAccounts, supportsMultipleAccounts: true),
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

  public static func descriptor(for id: String) -> HarnessDescriptor {
    byId[id] ?? HarnessDescriptor(id: id, displayName: humanized(id))
  }

  public static func displayName(for id: String, reported: String? = nil) -> String {
    if let reported, !reported.isEmpty { return reported }
    return descriptor(for: id).displayName
  }

  static func humanized(_ id: String) -> String {
    id.split(whereSeparator: { $0 == "-" || $0 == "_" })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}
