import Foundation

public struct HarnessProvider: Identifiable, Equatable, Sendable {
  public enum Credential: Equatable, Sendable {
    case providerAccount, apiKey, external
  }

  public let id: String
  public let name: String
  public var methods: [HarnessProviderMethod]
  public var credential: Credential?
  public var accountLabel: String?

  public init(
    id: String, name: String, methods: [HarnessProviderMethod], credential: Credential?, accountLabel: String? = nil
  ) {
    self.id = id
    self.name = name
    self.methods = methods
    self.credential = credential
    self.accountLabel = accountLabel
  }
}

public struct HarnessProviderMethod: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case providerAccount, apiKey
  }

  public let id: String
  public let label: String
  public let kind: Kind
  public let prompts: [HarnessProviderPrompt]

  public init(id: String, label: String, kind: Kind, prompts: [HarnessProviderPrompt] = []) {
    self.id = id
    self.label = label
    self.kind = kind
    self.prompts = prompts
  }
}

public struct HarnessProviderPrompt: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case text, secret, select

    init(piPromptType type: String) {
      switch type {
      case "select": self = .select
      case "secret": self = .secret
      default: self = .text
      }
    }
  }

  public struct Option: Identifiable, Equatable, Sendable {
    public let value: String
    public let label: String
    public var id: String { value }

    public init(value: String, label: String) {
      self.value = value
      self.label = label
    }
  }

  public struct Condition: Equatable, Sendable {
    public let key: String
    public let equals: Bool
    public let value: String

    public init(key: String, equals: Bool, value: String) {
      self.key = key
      self.equals = equals
      self.value = value
    }
  }

  public let id: String
  public let kind: Kind
  public let message: String
  public let placeholder: String?
  public let options: [Option]
  public let condition: Condition?
  public let isRequired: Bool
  public let defaultValue: String?

  public init(
    id: String, kind: Kind, message: String, placeholder: String? = nil, options: [Option] = [],
    condition: Condition? = nil, isRequired: Bool = true, defaultValue: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.message = message
    self.placeholder = placeholder
    self.options = options
    self.condition = condition
    self.isRequired = isRequired
    self.defaultValue = defaultValue
  }

  public func isShown(given answers: [String: String]) -> Bool {
    guard let condition else { return true }
    guard let actual = answers[condition.key] else { return false }
    return condition.equals ? actual == condition.value : actual != condition.value
  }
}

public struct HarnessProviderSignIn: Identifiable, Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case running
    case waiting
    case complete
    case failed(String)

    public var isPending: Bool { self == .running || self == .waiting }
  }

  public let id: String
  public var state: State
  public var url: String?
  public var instructions: String?
  public var userCode: String?
  public var prompt: HarnessProviderPrompt?
  public var harnessName: String?

  public init(
    id: String, state: State, url: String? = nil, instructions: String? = nil, userCode: String? = nil,
    prompt: HarnessProviderPrompt? = nil, harnessName: String? = nil
  ) {
    self.id = id
    self.state = state
    self.url = url
    self.instructions = instructions
    self.userCode = userCode
    self.prompt = prompt
    self.harnessName = harnessName
  }

  public var isHarnessCodeStep: Bool { harnessName != nil && state == .waiting }
}

@MainActor public protocol HarnessProviderBackend {
  func providers() async throws -> [HarnessProvider]
  func signIn(
    _ provider: HarnessProvider, method: HarnessProviderMethod, inputs: [String: String], apiKey: String?
  ) async throws -> HarnessProviderSignIn
  func answer(_ signIn: HarnessProviderSignIn, with value: String) async throws -> HarnessProviderSignIn
  func status(of signInId: String) async throws -> HarnessProviderSignIn
  func cancel(_ signInId: String) async
  func remove(_ provider: HarnessProvider) async throws
}

@MainActor public struct PiProviderBackend: HarnessProviderBackend {
  let store: HarnessAccountsStore

  public init(store: HarnessAccountsStore) { self.store = store }

  public func providers() async throws -> [HarnessProvider] {
    try await store.listPiAuthProviders().map { provider in
      HarnessProvider(
        id: provider.id, name: provider.name,
        methods: provider.methods.compactMap(Self.method),
        credential: provider.credentialType.flatMap(Self.credential))
    }
  }

  public func signIn(
    _ provider: HarnessProvider, method: HarnessProviderMethod, inputs: [String: String], apiKey: String?
  ) async throws -> HarnessProviderSignIn {
    if let apiKey, store.isShared {
      try await store.savePiKey(providerId: provider.id, key: apiKey)
      return HarnessProviderSignIn(id: UUID().uuidString, state: .complete)
    }
    let started = try await store.startPiAuth(providerId: provider.id, method: method.id)
    guard let apiKey, started.state == "waiting", started.prompt != nil else { return Self.signIn(started) }
    return Self.signIn(try await store.answerPiAuthFlow(id: started.id, value: apiKey))
  }

  public func answer(_ signIn: HarnessProviderSignIn, with value: String) async throws -> HarnessProviderSignIn {
    Self.signIn(try await store.answerPiAuthFlow(id: signIn.id, value: value))
  }

  public func status(of signInId: String) async throws -> HarnessProviderSignIn {
    Self.signIn(try await store.piAuthFlow(id: signInId))
  }

  public func cancel(_ signInId: String) async { try? await store.cancelPiAuthFlow(id: signInId) }

  public func remove(_ provider: HarnessProvider) async throws {
    try await store.removePiAuthProvider(id: provider.id)
  }

  static func method(_ id: String) -> HarnessProviderMethod? {
    switch id {
    case "oauth": HarnessProviderMethod(id: id, label: "Provider Account", kind: .providerAccount)
    case "api_key": HarnessProviderMethod(id: id, label: "API Key", kind: .apiKey)
    default: nil
    }
  }

  static func credential(_ type: String) -> HarnessProvider.Credential {
    type == "oauth" ? .providerAccount : .apiKey
  }

  static func signIn(_ flow: ServerPiAuthFlow) -> HarnessProviderSignIn {
    HarnessProviderSignIn(
      id: flow.id, state: state(flow.state, error: flow.error),
      url: flow.event?.url ?? flow.event?.verificationUrl,
      instructions: flow.event?.message, userCode: flow.event?.userCode,
      prompt: flow.prompt.map { prompt in
        HarnessProviderPrompt(
          id: prompt.id,
          kind: .init(piPromptType: prompt.type),
          message: prompt.message, placeholder: prompt.placeholder,
          options: prompt.options.map { .init(value: $0.id, label: $0.label) })
      })
  }
}

@MainActor public struct OpenCodeProviderBackend: HarnessProviderBackend {
  let store: HarnessAccountsStore
  let accountId: String

  public init(store: HarnessAccountsStore, accountId: String) {
    self.store = store
    self.accountId = accountId
  }

  public func providers() async throws -> [HarnessProvider] {
    try await store.listOpenCodeAuthProviders(accountId: accountId).map { provider in
      HarnessProvider(
        id: provider.id, name: provider.name,
        methods: provider.methods.map { method in
          HarnessProviderMethod(
            id: method.id, label: method.label, kind: method.type == "api" ? .apiKey : .providerAccount,
            prompts: method.prompts.map { prompt in
              HarnessProviderPrompt(
                id: prompt.key, kind: prompt.type == "select" ? .select : .text, message: prompt.message,
                placeholder: prompt.placeholder,
                options: prompt.options.map { option in
                  .init(
                    value: option.value,
                    label: option.hint.map { "\(option.label) — \($0)" } ?? option.label)
                },
                condition: prompt.when.map { .init(key: $0.key, equals: $0.op == "eq", value: $0.value) },
                isRequired: prompt.required ?? true, defaultValue: prompt.defaultValue)
            })
        },
        credential: provider.credentialType.map { type in
          switch type {
          case "oauth": .providerAccount
          case "wellknown": .external
          default: .apiKey
          }
        },
        accountLabel: provider.accountLabel)
    }
  }

  public func signIn(
    _ provider: HarnessProvider, method: HarnessProviderMethod, inputs: [String: String], apiKey: String?
  ) async throws -> HarnessProviderSignIn {
    Self.signIn(
      try await store.startOpenCodeAuth(
        accountId: accountId, providerId: provider.id, methodId: method.id,
        inputs: inputs.isEmpty ? nil : inputs, apiKey: apiKey))
  }

  public func answer(_ signIn: HarnessProviderSignIn, with value: String) async throws -> HarnessProviderSignIn {
    Self.signIn(try await store.answerOpenCodeAuthFlow(id: signIn.id, code: value))
  }

  public func status(of signInId: String) async throws -> HarnessProviderSignIn {
    Self.signIn(try await store.openCodeAuthFlow(id: signInId))
  }

  public func cancel(_ signInId: String) async { try? await store.cancelOpenCodeAuthFlow(id: signInId) }

  public func remove(_ provider: HarnessProvider) async throws {
    try await store.removeOpenCodeAuthProvider(accountId: accountId, providerId: provider.id)
  }

  static let codePrompt = HarnessProviderPrompt(id: "code", kind: .text, message: "Authorization Code")

  static func signIn(_ flow: ServerOpenCodeAuthFlow) -> HarnessProviderSignIn {
    HarnessProviderSignIn(
      id: flow.id, state: state(flow.state, error: flow.error), url: flow.authorization?.url,
      instructions: flow.authorization?.instructions.isEmpty == false ? flow.authorization?.instructions : nil,
      prompt: flow.state == "waiting" ? codePrompt : nil, harnessName: flow.harnessName)
  }
}

private func state(_ value: String, error: String?) -> HarnessProviderSignIn.State {
  switch value {
  case "running": .running
  case "waiting": .waiting
  case "complete": .complete
  default: .failed(error ?? "Sign-in failed.")
  }
}
