import Foundation
import Observation

@MainActor
@Observable
public final class GitSignInModel {
  public enum Step: Equatable, Sendable {
    case idle
    case starting(GitHostProvider)
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
    case let .starting(provider), let .waiting(provider, _), let .signedIn(provider, _),
      let .failed(provider, _):
      provider
    }
  }

  public func signIn(with provider: GitHostProvider) {
    pollTask?.cancel()
    step = .starting(provider)
    let host =
      suggestedHost.flatMap { GitHostProvider(host: $0) == provider ? $0 : nil } ?? provider.defaultHost
    pollTask = Task { [weak self] in
      guard let self else { return }
      do {
        var flow = try await client.startGitAuth(host: host)
        while !Task.isCancelled {
          switch flow.state {
          case .starting:
            break
          case .waiting:
            if step != .waiting(provider, flow) { step = .waiting(provider, flow) }
          case .complete:
            step = .signedIn(provider, account: flow.account)
            onSignedIn?(provider)
            return
          case .error:
            step = .failed(provider, message: flow.message ?? "Sign-in didn't finish.")
            return
          case .cancelled:
            step = .idle
            return
          }
          try await Task.sleep(for: pollInterval)
          flow = try await client.gitAuthFlow(id: flow.id)
        }
      } catch is CancellationError {
      } catch {
        step = .failed(provider, message: serverErrorMessage(error))
      }
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
