import CodevisorClient
import Observation

@MainActor
@Observable
public final class FirstRunClaudeCodeLogin {
  public enum Stage: Equatable, Sendable {
    case asking(ServerFirstRunClaudeCodeLogin)
    case signingIn
  }

  public private(set) var stage: Stage?
  public private(set) var isAnswering = false
  public private(set) var errorMessage: String?

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let feed: FirstRunStatusFeed
  @ObservationIgnored private var isFollowing = false
  @ObservationIgnored private var hasAnswered = false

  public init(client: any CodevisorServerClienting) {
    self.client = client
    feed = FirstRunStatusFeed(client: client)
  }

  public var isWaitingOnUser: Bool { stage != nil }

  public func follow() async {
    guard !isFollowing, await client.waitUntilConnected() else { return }
    isFollowing = true
    defer { feed.stop() }

    var seen: ServerFirstRunStatus?
    while !Task.isCancelled {
      guard let status = try? await feed.status(where: { $0 != seen }) else { return }
      seen = status
      show(status.claudeCodeLogin)
      if status.isFinal, status.claudeCodeLogin == nil { return }
    }
  }

  public func answer(_ choice: ServerFirstRunClaudeCodeLoginAnswer.Choice) async {
    isAnswering = true
    errorMessage = nil
    defer { isAnswering = false }
    do {
      _ = try await client.answerFirstRunClaudeCodeLogin(choice)
      hasAnswered = true
      stage = choice == .signIn ? .signingIn : nil
      captureAnswer(choice, succeeded: true)
    } catch {
      errorMessage = serverErrorMessage(error)
      captureAnswer(choice, succeeded: false)
    }
  }

  private func captureAnswer(_ choice: ServerFirstRunClaudeCodeLoginAnswer.Choice, succeeded: Bool) {
    Analytics.capture(
      .claudeCodeLoginAnswered,
      properties: ["choice": .string(choice.rawValue), "succeeded": .boolean(succeeded)]
    )
  }

  public func finishSigningIn() {
    guard stage == .signingIn else { return }
    stage = nil
  }

  private func show(_ question: ServerFirstRunClaudeCodeLogin?) {
    guard !hasAnswered else { return }
    stage = question.map(Stage.asking)
  }
}
