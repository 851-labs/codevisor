import Foundation
import Testing

@testable import CodevisorCore

/// A scripted provider backend: answers from its queues and records calls.
@MainActor
private final class FakeProviderBackend: HarnessProviderBackend {
  var catalog: Result<[HarnessProvider], any Error> = .success([])
  var started: [HarnessProviderSignIn] = []
  var answered: [HarnessProviderSignIn] = []
  var statuses: [HarnessProviderSignIn] = []
  var failure: (any Error)?
  private(set) var calls: [String] = []

  func providers() async throws -> [HarnessProvider] { try catalog.get() }

  func signIn(
    _ provider: HarnessProvider, method: HarnessProviderMethod, inputs: [String: String], apiKey: String?
  ) async throws -> HarnessProviderSignIn {
    calls.append("signIn \(provider.id) \(method.id) \(inputs) \(apiKey ?? "-")")
    if let failure { throw failure }
    return started.removeFirst()
  }

  func answer(_ signIn: HarnessProviderSignIn, with value: String) async throws -> HarnessProviderSignIn {
    calls.append("answer \(signIn.id) \(value)")
    return answered.removeFirst()
  }

  func status(of signInId: String) async throws -> HarnessProviderSignIn {
    calls.append("status \(signInId)")
    return statuses.removeFirst()
  }

  func cancel(_ signInId: String) async { calls.append("cancel \(signInId)") }

  func remove(_ provider: HarnessProvider) async throws {
    calls.append("remove \(provider.id)")
    if let failure { throw failure }
  }
}

private struct Failure: LocalizedError {
  let errorDescription: String?
}

private let oauth = HarnessProviderMethod(id: "oauth", label: "Provider Account", kind: .providerAccount)
private let key = HarnessProviderMethod(id: "api_key", label: "API Key", kind: .apiKey)
private let openai = HarnessProvider(id: "openai", name: "OpenAI", methods: [oauth, key], credential: .providerAccount)
private let anthropic = HarnessProvider(id: "anthropic", name: "Anthropic", methods: [key], credential: .apiKey)
private let xai = HarnessProvider(id: "xai", name: "xAI", methods: [oauth], credential: nil)
private let opened = HarnessProvider(id: "old", name: "Old", methods: [], credential: .providerAccount)

@MainActor
@Suite("Provider accounts")
struct HarnessProviderAccountsTests {
  @Test("A machine's accounts show only provider sign-ins, and a shared list shows keys too")
  func configured() async {
    let backend = FakeProviderBackend()
    backend.catalog = .success([openai, anthropic, xai, opened])
    let machine = HarnessProviderAccounts(backend: backend, providerAccountsOnly: true)
    #expect(machine.load == .loading)
    await machine.reload()
    #expect(machine.load == .loaded)
    #expect(machine.configured.map(\.id) == ["openai", "old"])
    // Keys can't be added here, and a provider left with no way in is kept only if signed in.
    #expect(machine.providers.map(\.id) == ["openai", "xai", "old"])
    #expect(machine.available.map(\.id) == ["openai", "xai"])
    #expect(machine.providers.first?.methods == [oauth])

    let shared = HarnessProviderAccounts(backend: backend, providerAccountsOnly: false)
    await shared.reload()
    #expect(shared.configured.map(\.id) == ["openai", "anthropic", "old"])
  }

  @Test("A failed first load says why; a later failure keeps the list and reports it")
  func failures() async {
    let backend = FakeProviderBackend()
    backend.catalog = .failure(Failure(errorDescription: "Machine offline"))
    let accounts = HarnessProviderAccounts(backend: backend, providerAccountsOnly: false)
    await accounts.reload()
    #expect(accounts.load == .failed("Machine offline"))
    backend.catalog = .success([openai])
    await accounts.reload()
    #expect(accounts.load == .loaded)
    backend.catalog = .failure(Failure(errorDescription: "Lost connection"))
    await accounts.reload()
    #expect(accounts.load == .loaded)
    #expect(accounts.providers == [openai])
    #expect(accounts.errorMessage == "Lost connection")
  }

  @Test("Removing a credential names the work and reloads, or reports why it couldn't")
  func remove() async {
    let backend = FakeProviderBackend()
    backend.catalog = .success([openai])
    let accounts = HarnessProviderAccounts(backend: backend, providerAccountsOnly: false)
    await accounts.reload()
    backend.catalog = .success([])
    await accounts.remove(openai)
    #expect(backend.calls == ["remove openai"])
    #expect(accounts.providers.isEmpty)
    #expect(!accounts.isWorking)
    backend.failure = Failure(errorDescription: "Not allowed")
    await accounts.remove(openai)
    #expect(accounts.errorMessage == "Not allowed")
  }

  @Test("The sheet starts on the first provider not yet signed in, with its first method")
  func defaults() {
    let backend = FakeProviderBackend()
    let draft = HarnessProviderSignInDraft(
      providers: [openai, xai], providerId: nil, backend: backend)
    #expect(draft.provider == xai)
    #expect(draft.method == oauth)
    #expect(!draft.isReplacing)
    #expect(draft.actionTitle == "Sign In")
    let replacing = HarnessProviderSignInDraft(
      providers: [openai, xai], providerId: "openai", backend: backend)
    #expect(replacing.isReplacing)
    replacing.methodId = "api_key"
    #expect(replacing.actionTitle == "Save")
    #expect(!replacing.canSubmit)
    replacing.apiKey = "  sk-1  "
    #expect(replacing.canSubmit)
    // Choosing another provider starts over with its own method.
    replacing.providerId = "xai"
    #expect(replacing.methodId == "oauth")
    #expect(replacing.apiKey.isEmpty)
    let empty = HarnessProviderSignInDraft(providers: [], providerId: nil, backend: backend)
    #expect(empty.provider == nil)
    #expect(!empty.canSubmit)
  }

  @Test("Prompts default to their first option and appear only when their condition holds")
  func prompts() async {
    let plan = HarnessProviderPrompt(
      id: "plan", kind: .select, message: "Plan",
      options: [.init(value: "pro", label: "Pro"), .init(value: "team", label: "Team")])
    let team = HarnessProviderPrompt(
      id: "team", kind: .text, message: "Team", condition: .init(key: "plan", equals: true, value: "team"))
    let notPro = HarnessProviderPrompt(
      id: "region", kind: .text, message: "Region", condition: .init(key: "plan", equals: false, value: "pro"))
    let missing = HarnessProviderPrompt(
      id: "other", kind: .text, message: "Other", condition: .init(key: "absent", equals: true, value: "x"))
    let method = HarnessProviderMethod(
      id: "m", label: "M", kind: .providerAccount, prompts: [plan, team, notPro, missing])
    let provider = HarnessProvider(id: "p", name: "P", methods: [method], credential: nil)
    let backend = FakeProviderBackend()
    backend.started = [.init(id: "s1", state: .complete)]
    let draft = HarnessProviderSignInDraft(providers: [provider], providerId: nil, backend: backend)
    #expect(draft.inputs == ["plan": "pro"])
    #expect(draft.visiblePrompts.map(\.id) == ["plan"])
    draft.inputs["plan"] = "team"
    #expect(draft.visiblePrompts.map(\.id) == ["plan", "team", "region"])
    #expect(!draft.canSubmit)
    draft.inputs["team"] = "core"
    draft.inputs["region"] = "us"
    await draft.submit()
    #expect(backend.calls.first?.hasPrefix("signIn p m") == true)
    #expect(draft.isComplete)
  }

  @Test("Saving a key finishes at once, and a refused sign-in says why")
  func saveKey() async {
    let backend = FakeProviderBackend()
    backend.started = [.init(id: "k", state: .complete)]
    let draft = HarnessProviderSignInDraft(
      providers: [anthropic], providerId: "anthropic", backend: backend)
    draft.apiKey = " sk-ant "
    await draft.submit()
    #expect(backend.calls == ["signIn anthropic api_key [:] sk-ant"])
    #expect(draft.isComplete)

    let refused = FakeProviderBackend()
    refused.failure = Failure(errorDescription: "Invalid key")
    let second = HarnessProviderSignInDraft(
      providers: [anthropic], providerId: "anthropic", backend: refused)
    second.apiKey = "bad"
    await second.submit()
    #expect(second.errorMessage == "Invalid key")
    #expect(!second.isComplete)
    // Nothing to submit does nothing.
    second.apiKey = ""
    await second.submit()
    #expect(refused.calls.count == 1)
  }

  @Test("A provider sign-in opens its page once and follows it until it finishes")
  func follow() async {
    let backend = FakeProviderBackend()
    let page = "https://auth.example/device"
    backend.started = [.init(id: "s", state: .running, url: page, userCode: "ABCD")]
    backend.statuses = [
      .init(id: "s", state: .running, url: page, userCode: "ABCD"),
      .init(id: "s", state: .complete),
    ]
    let draft = HarnessProviderSignInDraft(
      providers: [xai], providerId: nil, backend: backend,
      sleep: { _ in })
    await draft.submit()
    #expect(draft.signIn?.userCode == "ABCD")
    #expect(draft.status == "Waiting for sign-in…")
    #expect(draft.actionTitle == nil)
    await draft.follow()
    #expect(draft.isComplete)
    #expect(draft.pageToOpen == URL(string: page))
    #expect(backend.calls.filter { $0.hasPrefix("status") }.count == 2)
  }

  @Test("A sign-in that asks a question goes on with the answer, and a failed one says why")
  func answer() async {
    let backend = FakeProviderBackend()
    let question = HarnessProviderPrompt(
      id: "org", kind: .select, message: "Organization", options: [.init(value: "acme", label: "Acme")])
    backend.started = [.init(id: "q", state: .waiting, prompt: question)]
    backend.answered = [.init(id: "q", state: .failed("Code expired"))]
    let draft = HarnessProviderSignInDraft(providers: [xai], providerId: nil, backend: backend)
    await draft.submit()
    #expect(draft.answer == "acme")
    #expect(draft.actionTitle == "Continue")
    #expect(draft.canSubmit)
    await draft.submit()
    #expect(backend.calls.last == "answer q acme")
    #expect(draft.errorMessage == "Code expired")
    #expect(draft.signIn == nil)
    #expect(draft.actionTitle == "Sign In")
  }

  @Test("Closing the sheet abandons a sign-in still running, and stops following it")
  func dismissed() async {
    let backend = FakeProviderBackend()
    backend.started = [.init(id: "s", state: .running)]
    let draft = HarnessProviderSignInDraft(
      providers: [xai], providerId: nil, backend: backend,
      sleep: { _ in throw CancellationError() })
    await draft.submit()
    await draft.follow()
    #expect(draft.signIn?.id == "s")
    await draft.dismissed()
    #expect(backend.calls.last == "cancel s")
    #expect(draft.signIn == nil)
    // Nothing pending: nothing to cancel.
    await draft.dismissed()
    #expect(backend.calls.filter { $0.hasPrefix("cancel") }.count == 1)
  }

  @Test("Pi's and OpenCode's sign-ins read the same way")
  func conversions() throws {
    let decoder = JSONDecoder()
    let pi = try decoder.decode(
      ServerPiAuthFlow.self,
      from: Data(
        """
        {"id":"f","providerId":"openai","state":"waiting",
         "event":{"type":"device_code","verificationUrl":"https://v","userCode":"WXYZ","message":"Enter it"},
         "prompt":{"id":"p","type":"secret","message":"Key","options":[]}}
        """.utf8))
    let piSignIn = PiProviderBackend.signIn(pi)
    #expect(piSignIn.url == "https://v")
    #expect(piSignIn.userCode == "WXYZ")
    #expect(piSignIn.instructions == "Enter it")
    #expect(piSignIn.prompt?.kind == .secret)
    #expect(PiProviderBackend.method("unknown") == nil)
    #expect(PiProviderBackend.credential("api_key") == .apiKey)
    let failed = try decoder.decode(
      ServerPiAuthFlow.self, from: Data(#"{"id":"f","providerId":"x","state":"error"}"#.utf8))
    #expect(PiProviderBackend.signIn(failed).state == .failed("Sign-in failed."))

    let openCode = try decoder.decode(
      ServerOpenCodeAuthFlow.self,
      from: Data(
        """
        {"id":"o","accountId":"a","providerId":"openai","state":"waiting",
         "authorization":{"url":"https://auth","method":"code","instructions":""}}
        """.utf8))
    let openCodeSignIn = OpenCodeProviderBackend.signIn(openCode)
    #expect(openCodeSignIn.url == "https://auth")
    #expect(openCodeSignIn.instructions == nil)
    #expect(openCodeSignIn.prompt == OpenCodeProviderBackend.codePrompt)
  }
}
