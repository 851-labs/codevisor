import ACPKit
import CodevisorProtocol
import Foundation

public enum ServerHarnessReadinessState: Equatable, Sendable {
  case ready
  case unavailable
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "ready": self = .ready
    case "unavailable": self = .unavailable
    default: self = .unknown(rawValue)
    }
  }
}

public enum ServerHarnessAuthenticationState: Equatable, Sendable {
  case checking
  case authenticated
  case unauthenticated
  case expired
  case notRequired
  case unavailable
  case error
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "checking": self = .checking
    case "authenticated": self = .authenticated
    case "unauthenticated": self = .unauthenticated
    case "expired": self = .expired
    case "notRequired": self = .notRequired
    case "unavailable": self = .unavailable
    case "error": self = .error
    default: self = .unknown(rawValue)
    }
  }
}

public enum ServerHarnessLifecyclePhase: Equatable, Sendable {
  case idle
  case installing
  case updating
  case pendingUpdate
  case failed
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "idle": self = .idle
    case "installing": self = .installing
    case "updating": self = .updating
    case "pendingUpdate": self = .pendingUpdate
    case "failed": self = .failed
    default: self = .unknown(rawValue)
    }
  }
}

public struct ServerHarnessReadiness: Codable, Equatable, Sendable {
  public var state: String
  public var detail: String?
  /// Resolved binary location and probed version for ready harnesses.
  public var path: String?
  public var version: String?

  public init(state: String, detail: String? = nil, path: String? = nil, version: String? = nil) {
    self.state = state
    self.detail = detail
    self.path = path
    self.version = version
  }
}

/// One way the server can install a harness CLI on its machine, mirroring
/// `HarnessInstallMethod` in @codevisor/api.
public struct ServerHarnessInstallMethod: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var label: String
  /// The exact shell command that would run — shown verbatim before install.
  public var command: String
  public var available: Bool
  public var recommended: Bool

  public init(
    id: String,
    kind: String,
    label: String,
    command: String,
    available: Bool,
    recommended: Bool
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.command = command
    self.available = available
    self.recommended = recommended
  }
}

/// Latest-version knowledge for an installed harness, mirroring
/// `HarnessUpdateInfo` in @codevisor/api.
public struct ServerHarnessUpdateInfo: Codable, Equatable, Sendable {
  public var installedVersion: String?
  public var latestVersion: String?
  public var updateAvailable: Bool
  public var source: String?
  public var installOrigin: String?
  public var channel: String?
  public var checkedAt: String?

  public init(
    installedVersion: String? = nil,
    latestVersion: String? = nil,
    updateAvailable: Bool,
    source: String? = nil,
    installOrigin: String? = nil,
    channel: String? = nil,
    checkedAt: String? = nil
  ) {
    self.installedVersion = installedVersion
    self.latestVersion = latestVersion
    self.updateAvailable = updateAvailable
    self.source = source
    self.installOrigin = installOrigin
    self.channel = channel
    self.checkedAt = checkedAt
  }
}

/// Live install/update state for one harness, mirroring
/// `HarnessLifecycleState` in @codevisor/api. `phase` is one of
/// idle/installing/updating/pendingUpdate/failed.
public struct ServerHarnessLifecycleState: Codable, Equatable, Sendable {
  public var phase: String
  public var targetVersion: String?
  public var methodId: String?
  /// Background terminal streaming the operation's output ("Show Output").
  public var terminalId: String?
  public var error: String?
  public var startedAt: String?

  public init(
    phase: String,
    targetVersion: String? = nil,
    methodId: String? = nil,
    terminalId: String? = nil,
    error: String? = nil,
    startedAt: String? = nil
  ) {
    self.phase = phase
    self.targetVersion = targetVersion
    self.methodId = methodId
    self.terminalId = terminalId
    self.error = error
    self.startedAt = startedAt
  }
}

/// A user-defined custom ACP harness spec, mirroring `CustomHarnessSpec` in
/// @codevisor/api. Launched server-side as `command args…` with `env` merged
/// into the spawn environment.
public struct ServerCustomHarnessSpec: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var command: String
  public var args: [String]?
  public var env: [String: String]?

  public init(
    id: String,
    name: String,
    command: String,
    args: [String]? = nil,
    env: [String: String]? = nil
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.args = args
    self.env = env
  }
}

/// Result of the ACP initialize handshake probe ("Test Connection"),
/// mirroring `CustomHarnessTestResult` in @codevisor/api.
public struct ServerCustomHarnessTestResult: Codable, Equatable, Sendable {
  public var ok: Bool
  public var agentName: String?
  public var protocolVersion: Int?
  public var error: String?

  public init(ok: Bool, agentName: String? = nil, protocolVersion: Int? = nil, error: String? = nil) {
    self.ok = ok
    self.agentName = agentName
    self.protocolVersion = protocolVersion
    self.error = error
  }
}

/// Wire wrapper for the custom-harness list routes.
struct ServerCustomHarnessListEnvelope: Codable, Equatable, Sendable {
  var harnesses: [ServerCustomHarnessSpec]
}

/// Dual-install: a desktop app bundling a copy of the harness CLI, with its
/// own Sparkle-fed update state. Mirrors `HarnessBundledApp` in @codevisor/api.
public struct ServerHarnessBundledApp: Codable, Equatable, Sendable {
  public var appName: String
  public var bundlePath: String
  public var installedVersion: String?
  public var latestVersion: String?
  public var updateAvailable: Bool

  public init(
    appName: String,
    bundlePath: String,
    installedVersion: String? = nil,
    latestVersion: String? = nil,
    updateAvailable: Bool
  ) {
    self.appName = appName
    self.bundlePath = bundlePath
    self.installedVersion = installedVersion
    self.latestVersion = latestVersion
    self.updateAvailable = updateAvailable
  }
}

/// 202 ack for install/update starts.
public struct ServerHarnessOperationStarted: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var terminalId: String?
  public var queued: Bool?
  /// Authoritative state installed by the server before it acknowledges the
  /// operation. Optional for compatibility with older servers.
  public var lifecycle: ServerHarnessLifecycleState?

  public init(
    accepted: Bool,
    terminalId: String? = nil,
    queued: Bool? = nil,
    lifecycle: ServerHarnessLifecycleState? = nil
  ) {
    self.accepted = accepted
    self.terminalId = terminalId
    self.queued = queued
    self.lifecycle = lifecycle
  }
}

public struct ServerHarness: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var symbolName: String
  public var source: String
  public var launchKind: String
  public var enabled: Bool
  public var desiredEnabled: Bool?
  public var readiness: ServerHarnessReadiness
  public var auth: ServerHarnessAuth?
  /// Copyable shell command that installs the harness CLI; present only for
  /// harnesses with a well-known installer.
  public var installHint: String?
  /// Ways the server can install this harness on its machine. Absent on
  /// servers that predate lifecycle management.
  public var installMethods: [ServerHarnessInstallMethod]?
  /// Latest-version knowledge from the server's periodic update check.
  public var updateInfo: ServerHarnessUpdateInfo?
  /// Live install/update operation state.
  public var lifecycle: ServerHarnessLifecycleState?

  public init(
    id: String,
    name: String,
    symbolName: String,
    source: String,
    launchKind: String,
    enabled: Bool,
    readiness: ServerHarnessReadiness,
    installHint: String? = nil,
    desiredEnabled: Bool? = nil,
    auth: ServerHarnessAuth? = nil,
    installMethods: [ServerHarnessInstallMethod]? = nil,
    updateInfo: ServerHarnessUpdateInfo? = nil,
    lifecycle: ServerHarnessLifecycleState? = nil
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.source = source
    self.launchKind = launchKind
    self.enabled = enabled
    self.desiredEnabled = desiredEnabled
    self.readiness = readiness
    self.installHint = installHint
    self.auth = auth
    self.installMethods = installMethods
    self.updateInfo = updateInfo
    self.lifecycle = lifecycle
  }
}

public struct ServerHarnessAuthMethod: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var kind: String
}

public struct ServerHarnessAccount: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var harnessId: String
  public var profileKind: String
  public var label: String
  public var email: String?
  public var organizationId: String?
  public var authMethod: String?
  public var authState: String
  public var isActive: Bool
  public var canLogin: Bool
  public var canLogout: Bool
  public var lastCheckedAt: String?
  public var detail: String?
}

public struct ServerHarnessAuth: Codable, Equatable, Sendable {
  public var state: String
  public var activeAccountId: String?
  public var accounts: [ServerHarnessAccount]
  public var loginMethods: [ServerHarnessAuthMethod]
  public var supportsMultipleAccounts: Bool
}

public extension ServerHarnessReadiness {
  var resolvedState: ServerHarnessReadinessState { .init(rawValue: state) }
}

public extension ServerHarnessLifecycleState {
  var resolvedPhase: ServerHarnessLifecyclePhase { .init(rawValue: phase) }
}

public extension ServerHarnessAuth {
  var resolvedState: ServerHarnessAuthenticationState { .init(rawValue: state) }

  var isSatisfied: Bool {
    resolvedState == .authenticated || resolvedState == .notRequired
  }
}

public extension ServerHarness {
  /// The user's persisted fleet preference. Older servers only return the
  /// effective value, so preserve that as a compatibility fallback.
  var isDesiredEnabled: Bool { desiredEnabled ?? enabled }

  /// Whether the server can expose this harness to new chats right now,
  /// after readiness and authentication gates have been applied.
  var isEffectivelyEnabled: Bool { enabled }

  /// True only when this harness declares authentication and that
  /// requirement has not yet been satisfied.
  var requiresAuthentication: Bool {
    guard let auth else { return false }
    return !auth.isSatisfied
  }
}

public struct ServerHarnessAuthFlow: Codable, Equatable, Sendable {
  public var id: String
  public var accountId: String
  public var kind: String
  public var url: String?
  public var verificationUrl: String?
  public var userCode: String?
  public var terminalId: String?
  public var terminalKey: String?

  /// The session key used by the terminal proxy. Older servers only sent
  /// `terminalId`, so keep that as a compatibility fallback.
  public var terminalAttachKey: String? { terminalKey ?? terminalId }
}

public struct ServerPiAuthProvider: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var methods: [String]
  public var credentialType: String?
}

public struct ServerPiAuthPromptOption: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var description: String?
}

public struct ServerPiAuthPrompt: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var type: String
  public var message: String
  public var placeholder: String?
  public var options: [ServerPiAuthPromptOption]
}

public struct ServerPiAuthEvent: Codable, Equatable, Sendable {
  public var type: String
  public var message: String?
  public var url: String?
  public var userCode: String?
  public var verificationUrl: String?
}

public struct ServerPiAuthFlow: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var providerId: String
  public var state: String
  public var prompt: ServerPiAuthPrompt?
  public var event: ServerPiAuthEvent?
  public var error: String?
}

public struct ServerOpenCodeAuthPromptCondition: Codable, Equatable, Sendable {
  public var key: String
  public var op: String
  public var value: String
}

public struct ServerOpenCodeAuthPromptOption: Codable, Equatable, Identifiable, Sendable {
  public var value: String
  public var label: String
  public var hint: String?
  public var id: String { value }
}

public struct ServerOpenCodeAuthPrompt: Codable, Equatable, Identifiable, Sendable {
  public var type: String
  public var key: String
  public var message: String
  public var placeholder: String?
  public var options: [ServerOpenCodeAuthPromptOption]
  public var when: ServerOpenCodeAuthPromptCondition?
  public var id: String { key }
}

public struct ServerOpenCodeAuthMethod: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var type: String
  public var label: String
  public var prompts: [ServerOpenCodeAuthPrompt]
}

public struct ServerOpenCodeAuthProvider: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var methods: [ServerOpenCodeAuthMethod]
  public var credentialType: String?
}

public struct ServerOpenCodeAuthAuthorization: Codable, Equatable, Sendable {
  public var url: String
  public var method: String
  public var instructions: String
}

public struct ServerOpenCodeAuthFlow: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var accountId: String
  public var providerId: String
  public var state: String
  public var authorization: ServerOpenCodeAuthAuthorization?
  public var error: String?
}

public struct ServerHarnessCapability: Codable, Equatable, Sendable {
  public var harness: ServerHarness
  public var modes: SessionModeState?
  public var configOptions: [SessionConfigOption]
  /// Whether the harness supports persistent session goals (codex goal mode).
  public var supportsGoals: Bool?

  public init(
    harness: ServerHarness,
    modes: SessionModeState? = nil,
    configOptions: [SessionConfigOption],
    supportsGoals: Bool? = nil
  ) {
    self.harness = harness
    self.modes = modes
    self.configOptions = configOptions
    self.supportsGoals = supportsGoals
  }
}
