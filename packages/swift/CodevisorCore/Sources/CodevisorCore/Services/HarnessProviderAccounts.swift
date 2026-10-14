import Foundation
import Observation

@MainActor @Observable public final class HarnessProviderAccounts {
  public enum Load: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
  }

  public let backend: any HarnessProviderBackend
  public let providerAccountsOnly: Bool
  public private(set) var providers: [HarnessProvider] = []
  public private(set) var load: Load = .loading
  public private(set) var workingLabel: String?
  public var errorMessage: String?

  public init(backend: any HarnessProviderBackend, providerAccountsOnly: Bool) {
    self.backend = backend
    self.providerAccountsOnly = providerAccountsOnly
  }

  public var isWorking: Bool { workingLabel != nil }

  public var configured: [HarnessProvider] {
    providers.filter { provider in
      guard let credential = provider.credential else { return false }
      return !providerAccountsOnly || credential == .providerAccount
    }
  }

  public var available: [HarnessProvider] { providers.filter { !$0.methods.isEmpty } }

  public func reload() async {
    if case .failed = load { load = .loading }
    do {
      let loaded = try await backend.providers()
      providers =
        providerAccountsOnly
        ? loaded.compactMap { provider in
          var local = provider
          local.methods = provider.methods.filter { $0.kind == .providerAccount }
          return local.methods.isEmpty && local.credential != .providerAccount ? nil : local
        } : loaded
      load = .loaded
      errorMessage = nil
    } catch {
      if load == .loaded {
        errorMessage = serverErrorMessage(error)
      } else {
        load = .failed(serverErrorMessage(error))
      }
    }
  }

  public func remove(_ provider: HarnessProvider) async {
    await perform("Removing credential…") {
      try await backend.remove(provider)
      await reload()
    }
  }

  func perform(_ label: String, _ operation: () async throws -> Void) async {
    workingLabel = label
    errorMessage = nil
    defer { workingLabel = nil }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }
}

@MainActor @Observable public final class HarnessProviderSignInDraft {
  public let providers: [HarnessProvider]
  public let isReplacing: Bool
  public var providerId: String {
    didSet { if providerId != oldValue { selectDefaultMethod() } }
  }
  public var methodId = "" {
    didSet { if methodId != oldValue { resetInputs() } }
  }
  public var inputs: [String: String] = [:]
  public var apiKey = ""
  public var answer = ""
  public private(set) var signIn: HarnessProviderSignIn?
  public private(set) var workingLabel: String?
  public var errorMessage: String?
  public private(set) var isComplete = false
  public private(set) var pageToOpen: URL?

  private let backend: any HarnessProviderBackend
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    providers: [HarnessProvider], providerId: String?, backend: any HarnessProviderBackend,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.providers = providers
    self.isReplacing = providerId != nil
    self.providerId =
      providerId ?? providers.first(where: { $0.credential == nil })?.id ?? providers.first?.id ?? ""
    self.backend = backend
    self.sleep = sleep
    selectDefaultMethod()
  }

  public var provider: HarnessProvider? { providers.first { $0.id == providerId } }
  public var method: HarnessProviderMethod? { provider?.methods.first { $0.id == methodId } }
  public var visiblePrompts: [HarnessProviderPrompt] {
    method?.prompts.filter { $0.isShown(given: inputs) } ?? []
  }
  public var isWorking: Bool { workingLabel != nil }

  public var status: String? {
    if signIn?.state == .running { return "Waiting for sign-in…" }
    return workingLabel
  }

  public var actionTitle: String? {
    guard let signIn else { return method?.kind == .apiKey ? "Save" : "Sign In" }
    return signIn.state == .waiting && signIn.prompt != nil ? "Continue" : nil
  }

  public var canSubmit: Bool {
    guard !isWorking else { return false }
    if let signIn {
      return signIn.state == .waiting && !answer.trimmed.isEmpty
    }
    guard let method else { return false }
    if method.kind == .apiKey && apiKey.trimmed.isEmpty { return false }
    return visiblePrompts.allSatisfy { !(inputs[$0.id] ?? "").trimmed.isEmpty }
  }

  public func submit() async {
    guard canSubmit else { return }
    if let signIn {
      await perform("Verifying…") {
        let value = answer.trimmed
        answer = ""
        apply(try await backend.answer(signIn, with: value))
      }
      return
    }
    guard let provider, let method else { return }
    let key = method.kind == .apiKey ? apiKey.trimmed : nil
    await perform(key == nil ? "Starting sign-in…" : "Saving…") {
      apply(
        try await backend.signIn(
          provider, method: method, inputs: visiblePrompts.isEmpty ? [:] : inputs, apiKey: key))
    }
  }

  public func follow() async {
    while let current = signIn, current.state.isPending, !isComplete {
      do { try await sleep(.seconds(1)) } catch { return }
      guard signIn?.id == current.id else { continue }
      if let next = try? await backend.status(of: current.id), signIn?.id == current.id {
        apply(next)
      }
    }
  }

  public func dismissed() async {
    guard let signIn, signIn.state.isPending else { return }
    self.signIn = nil
    await backend.cancel(signIn.id)
  }

  private func apply(_ next: HarnessProviderSignIn) {
    if let value = next.url, value != pageToOpen?.absoluteString, let url = URL(string: value) {
      pageToOpen = url
    }
    switch next.state {
    case .complete:
      signIn = nil
      isComplete = true
    case .failed(let message):
      signIn = nil
      errorMessage = message
    case .running, .waiting:
      signIn = next
      if next.prompt?.kind == .select, answer.isEmpty { answer = next.prompt?.options.first?.value ?? "" }
    }
  }

  private func perform(_ label: String, _ operation: () async throws -> Void) async {
    workingLabel = label
    errorMessage = nil
    defer { workingLabel = nil }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }

  private func selectDefaultMethod() {
    methodId = provider?.methods.first?.id ?? ""
    resetInputs()
  }

  private func resetInputs() {
    inputs = [:]
    apiKey = ""
    for prompt in method?.prompts ?? [] where prompt.kind == .select {
      inputs[prompt.id] = prompt.options.first?.value ?? ""
    }
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
