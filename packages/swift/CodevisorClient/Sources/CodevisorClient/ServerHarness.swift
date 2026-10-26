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
  case uninstalling
  case updating
  case pendingUpdate
  case failed
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "idle": self = .idle
    case "installing": self = .installing
    case "uninstalling": self = .uninstalling
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
  public var path: String?
  public var version: String?

  public init(state: String, detail: String? = nil, path: String? = nil, version: String? = nil) {
    self.state = state
    self.detail = detail
    self.path = path
    self.version = version
  }

  public var resolvedState: ServerHarnessReadinessState { .init(rawValue: state) }
}

public struct ServerHarnessInstallMethod: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var label: String
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

public struct ServerHarnessUpdateInfo: Codable, Equatable, Sendable {
  public var installedVersion: String?
  public var latestVersion: String?
  public var updateAvailable: Bool
  public var source: String?
  public var installOrigin: String?
  public var channel: String?
  public var checkedAt: String?
  public var notes: String?

  public init(
    installedVersion: String? = nil,
    latestVersion: String? = nil,
    updateAvailable: Bool,
    source: String? = nil,
    installOrigin: String? = nil,
    channel: String? = nil,
    checkedAt: String? = nil,
    notes: String? = nil
  ) {
    self.notes = notes
    self.installedVersion = installedVersion
    self.latestVersion = latestVersion
    self.updateAvailable = updateAvailable
    self.source = source
    self.installOrigin = installOrigin
    self.channel = channel
    self.checkedAt = checkedAt
  }
}

public struct ServerHarnessLifecycleState: Codable, Equatable, Sendable {
  public var phase: String
  public var targetVersion: String?
  public var methodId: String?
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

  public var resolvedPhase: ServerHarnessLifecyclePhase { .init(rawValue: phase) }
}

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

public struct ServerHarnessOperationStarted: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var terminalId: String?
  public var queued: Bool?
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
  public var settings: ServerHarnessSettings?
  public var readiness: ServerHarnessReadiness
  public var auth: ServerHarnessAuth?
  public var installHint: String?
  public var installMethods: [ServerHarnessInstallMethod]?
  public var updateInfo: ServerHarnessUpdateInfo?
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
    lifecycle: ServerHarnessLifecycleState? = nil,
    settings: ServerHarnessSettings? = nil
  ) {
    self.settings = settings
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

  public var isDesiredEnabled: Bool { desiredEnabled ?? enabled }
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
  public var selectionScope: String?
  public var canLogin: Bool
  public var canLogout: Bool
  public var lastCheckedAt: String?
  public var detail: String?
}

public struct ServerHarnessNotice: Codable, Equatable, Sendable {
  public var id: String
  public var message: String
}

public struct ServerHarnessAuth: Codable, Equatable, Sendable {
  public var state: String
  public var activeAccountId: String?
  public var accounts: [ServerHarnessAccount]
  public var loginMethods: [ServerHarnessAuthMethod]
  public var supportsMultipleAccounts: Bool
  public var notice: ServerHarnessNotice?

  public var resolvedState: ServerHarnessAuthenticationState { .init(rawValue: state) }

  public var isSatisfied: Bool {
    resolvedState == .authenticated || resolvedState == .notRequired
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
  public var required: Bool?
  public var defaultValue: String?
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
  public var supportsGoals: Bool?
  public var supportsSteering: Bool?
  public var skills: SessionSkills?
  public var unappliedConfigSelections: [String: String]?

  public init(
    harness: ServerHarness,
    modes: SessionModeState? = nil,
    configOptions: [SessionConfigOption],
    supportsGoals: Bool? = nil,
    supportsSteering: Bool? = nil,
    skills: SessionSkills? = nil,
    unappliedConfigSelections: [String: String]? = nil
  ) {
    self.harness = harness
    self.modes = modes
    self.configOptions = configOptions
    self.supportsGoals = supportsGoals
    self.supportsSteering = supportsSteering
    self.skills = skills
    self.unappliedConfigSelections = unappliedConfigSelections
  }
}
