import Foundation
import Observation

@MainActor
@Observable
public final class GitSignInModel {
  public enum Step: Equatable, Sendable {
    case idle
    case starting(GitHostProvider)
    case confirmingSetup(GitHostProvider)
    case installing(GitHostProvider)
    case waiting(GitHostProvider, ServerGitAuthFlow)
    case signedIn(GitHostProvider, account: String?)
    case failed(GitHostProvider, message: String)
  }

  public let machineName: String
  public private(set) var step: Step = .idle
  @ObservationIgnored public var onSignedIn: ((GitHostProvider) -> Void)?
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let suggestedHost: String?
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private let pollInterval: Duration

  public init(
    client: any CodevisorServerClienting,
    machineName: String,
    suggestedHost: String?,
    pollInterval: Duration = .seconds(1)
  ) {
    self.client = client
    self.machineName = machineName
    self.suggestedHost = suggestedHost?.lowercased()
    self.pollInterval = pollInterval
  }

  public var provider: GitHostProvider? {
    switch step {
    case .idle: nil
    case let .starting(provider), let .confirmingSetup(provider), let .installing(provider),
      let .waiting(provider, _), let .signedIn(provider, _), let .failed(provider, _):
      provider
    }
  }

  public var activity: String? {
    switch step {
    case .starting: "Starting sign-in…"
    case let .installing(provider): "Setting up \(provider.displayName)…"
    case .waiting: "Waiting for sign-in…"
    case .idle, .confirmingSetup, .signedIn, .failed: nil
    }
  }

  public func signIn(with provider: GitHostProvider) {
    begin(provider, confirmingSetup: true)
  }

  public func setUp() {
    guard case let .confirmingSetup(provider) = step else { return }
    begin(provider, confirmingSetup: false)
  }

  public func retry() {
    guard case let .failed(provider, _) = step else { return }
    begin(provider, confirmingSetup: false)
  }

  private func begin(_ provider: GitHostProvider, confirmingSetup: Bool) {
    pollTask?.cancel()
    step = .starting(provider)
    let host = host(for: provider)
    pollTask = Task { [weak self] in
      guard let self else { return }
      if confirmingSetup, await needsSetup(host) {
        guard !Task.isCancelled else { return }
        step = .confirmingSetup(provider)
        return
      }
      await follow(provider, host: host)
    }
  }

  private func host(for provider: GitHostProvider) -> String {
    suggestedHost.flatMap { GitHostProvider(host: $0) == provider ? $0 : nil } ?? provider.defaultHost
  }

  private func needsSetup(_ host: String) async -> Bool {
    guard let status = try? await client.gitAuthStatus(host: host) else { return false }
    return status.supported && !status.cliInstalled
  }

  private func follow(_ provider: GitHostProvider, host: String) async {
    do {
      var flow = try await client.startGitAuth(host: host)
      while !Task.isCancelled {
        guard track(flow, for: provider) else { return }
        try await Task.sleep(for: pollInterval)
        flow = try await client.gitAuthFlow(id: flow.id)
      }
    } catch is CancellationError {
    } catch {
      step = .failed(provider, message: serverErrorMessage(error))
    }
  }

  private func track(_ flow: ServerGitAuthFlow, for provider: GitHostProvider) -> Bool {
    switch flow.state {
    case .starting:
      let next: Step = flow.installing == true ? .installing(provider) : .starting(provider)
      if step != next { step = next }
      return true
    case .waiting:
      if step != .waiting(provider, flow) { step = .waiting(provider, flow) }
      return true
    case .complete:
      step = .signedIn(provider, account: flow.account)
      onSignedIn?(provider)
      return false
    case .error:
      step = .failed(provider, message: flow.message ?? "Sign-in didn't finish.")
      return false
    case .cancelled:
      step = .idle
      return false
    }
  }

  public func cancel() {
    pollTask?.cancel()
    pollTask = nil
    if case let .waiting(_, flow) = step {
      let client = client
      Task { try? await client.cancelGitAuth(id: flow.id) }
    }
    step = .idle
  }
}
