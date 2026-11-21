import CodevisorClient
import CodevisorTestSupport
import Testing

@testable import CodevisorCore

@MainActor
@Suite("First-run Claude Code sign-in question")
struct FirstRunClaudeCodeLoginTests {
  private static let question = ServerFirstRunClaudeCodeLogin(email: "me@example.com")

  @Test("Asks while the server waits, and stays answered when an older status still carries the question")
  func staysAnswered() async {
    let client = FirstRunQuestionsClient(status: ServerFirstRunStatus(state: .running, claudeCodeLogin: Self.question))
    let login = FirstRunClaudeCodeLogin(client: client)
    let following = Task { await login.follow() }
    await awaitObserved { login.stage == .asking(Self.question) }

    await login.answer(.notNow)
    client.publish(
      ServerFirstRunStatus(state: .running, projects: [.init(id: "p", name: "api")], claudeCodeLogin: Self.question))
    client.publish(ServerFirstRunStatus(state: .done, projects: [.init(id: "p", name: "api")]))
    await following.value

    #expect(client.claudeCodeLoginAnswers == [.notNow])
    #expect(!login.isWaitingOnUser)
  }

  @Test("Keeps onboarding waiting through sign-in until the sign-in sheet closes")
  func waitsThroughSignIn() async {
    let client = FirstRunQuestionsClient(status: ServerFirstRunStatus(state: .done, claudeCodeLogin: Self.question))
    let login = FirstRunClaudeCodeLogin(client: client)
    let following = Task { await login.follow() }
    await awaitObserved { login.isWaitingOnUser }

    await login.answer(.signIn)
    client.publish(ServerFirstRunStatus(state: .done))
    await following.value
    #expect(login.stage == .signingIn)

    login.finishSigningIn()
    #expect(!login.isWaitingOnUser)
  }

  @Test("Keeps asking with the server's reason when the transfer fails")
  func keepsAskingAfterAFailedTransfer() async {
    let client = FirstRunQuestionsClient(
      status: ServerFirstRunStatus(state: .done, claudeCodeLogin: Self.question), refusesAnswers: true)
    let login = FirstRunClaudeCodeLogin(client: client)
    let following = Task { await login.follow() }
    await awaitObserved { login.isWaitingOnUser }

    await login.answer(.transfer)

    #expect(login.stage == .asking(Self.question))
    #expect(login.errorMessage == "Couldn't move it")
    #expect(!login.isAnswering)
    following.cancel()
  }
}
