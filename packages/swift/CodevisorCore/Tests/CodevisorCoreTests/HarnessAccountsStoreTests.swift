import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("HarnessAccountsStore")
struct HarnessAccountsStoreTests {
  @Test("Provider OAuth starts in shared scope and subsequent prompts stay on the selected host")
  func providerOAuth() async throws {
    let transport = ProviderAccountTestTransport()
    let environment = AppEnvironment(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineClientFactory: { _ in
        CodevisorServerClient(config: .init(baseURL: URL(string: "http://fixture.test")!, requestTransport: transport))
      }
    )
    let store = HarnessAccountsStore(environment: environment, machineId: "local", isShared: true)
    let pi = try await store.startPiAuth(providerId: "anthropic", method: "oauth")
    #expect(pi.id == "native-pi")
    #expect(try await store.answerPiAuthFlow(id: pi.id, value: "fixture-code").state == "complete")
    try await store.cancelPiAuthFlow(id: pi.id)
    let opencode = try await store.startOpenCodeAuth(
      accountId: "default", providerId: "openai", methodId: "0", inputs: ["plan": "plus"], apiKey: nil)
    #expect(opencode.id == "native-opencode")
    #expect(try await store.answerOpenCodeAuthFlow(id: opencode.id, code: "fixture-code").state == "complete")
    try await store.cancelOpenCodeAuthFlow(id: opencode.id)
    let paths = await transport.paths
    #expect(paths.contains("/v1/harnesses/pi/shared-accounts"))
    #expect(paths.contains("/v1/harnesses/opencode/shared-accounts"))
    #expect(paths.contains("/v1/harnesses/pi/auth-flows/native-pi/answer"))
    #expect(paths.contains("/v1/harnesses/opencode/auth-flows/native-opencode/answer"))
    #expect(!paths.contains(where: { $0.contains("/providers/") && $0.hasSuffix("/login") }))
    #expect(environment.configSync.value(namespace: HarnessSharedCredentials.namespace, key: "pi-auth") == nil)
  }
  @Test("Grok account management and device sign-in stay in shared scope")
  func grokSharedAccount() async throws {
    let transport = SharedAccountTestTransport()
    let environment = AppEnvironment(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineClientFactory: { _ in
        CodevisorServerClient(config: .init(baseURL: URL(string: "http://fixture.test")!, requestTransport: transport))
      }
    )
    let store = HarnessAccountsStore(environment: environment, machineId: "local", isShared: true)
    let account = try #require(try await store.listHarnessAccounts(harnessId: "grok-build").first)
    let flow = try await store.loginHarnessAccount(
      harnessId: "grok-build", accountId: account.id, methodId: "grok.com", apiKey: nil)
    #expect(flow.kind == "deviceCode")
    #expect(flow.userCode == "ABCD-EFGH")
    #expect(flow.verificationUrl == "https://auth.x.ai/device")
    try await store.cancelHarnessLogin(harnessId: "grok-build", accountId: account.id, flowId: flow.id)
    #expect(
      try await store.loginHarnessAccount(
        harnessId: "grok-build", accountId: account.id, methodId: "apiKey", apiKey: "fixture-key"
      ).kind == "complete")
    #expect(
      try await store.probeHarnessAccount(harnessId: "grok-build", accountId: account.id).authState == "authenticated")
    #expect(
      try await store.activateHarnessAccount(harnessId: "grok-build", accountId: account.id).first?.isActive == true)
    #expect(
      try await store.logoutHarnessAccount(harnessId: "grok-build", accountId: account.id).authState
        == "unauthenticated")
    #expect(await transport.requests.allSatisfy { $0 == "/v1/harnesses/grok-build/shared-accounts" })
  }

  @Test("Shared profiles use the existing editor operations and remain distinct from machine accounts")
  func profiles() async throws {
    let environment = AppEnvironment.preview(seedProjects: [])
    let store = HarnessAccountsStore(environment: environment, machineId: "local", isShared: true)
    #expect(try store.sharedHarness(id: "opencode", name: "OpenCode").auth?.supportsMultipleAccounts == true)
    #expect(try await store.listHarnessAccounts(harnessId: "opencode").map(\.id) == ["default"])
    let profile = try await store.createHarnessAccount(harnessId: "opencode", label: "Work")
    #expect(profile.id.hasPrefix("shared-"))
    let flow = try await store.startOpenCodeAuth(
      accountId: profile.id, providerId: "openai", methodId: "0", inputs: ["organization": "team"], apiKey: "test-key")
    #expect(flow.state == "complete")
    #expect(try await store.listHarnessAccounts(harnessId: "opencode").last?.authState == "authenticated")
    let renamed = try await store.renameHarnessAccount(harnessId: "opencode", accountId: profile.id, label: "Team")
    #expect(renamed.label == "Team")
    let accounts = try await store.activateHarnessAccount(harnessId: "opencode", accountId: profile.id)
    #expect(accounts.last?.isActive == true)
    try await store.removeOpenCodeAuthProvider(accountId: profile.id, providerId: "openai")
    #expect(try await store.listHarnessAccounts(harnessId: "opencode").last?.authState == "unauthenticated")
    try await store.removeHarnessAccount(harnessId: "opencode", accountId: profile.id)
    #expect(try await store.listHarnessAccounts(harnessId: "opencode").first?.isActive == true)
    #expect(
      environment.configSync.value(namespace: HarnessSharedCredentials.namespace, key: "opencode-profile:\(profile.id)")
        == nil)
  }

  @Test("Shared Pi credentials use their native login operations")
  func staticCredentials() async throws {
    let environment = AppEnvironment.preview(seedProjects: [])
    let store = HarnessAccountsStore(environment: environment, machineId: "local", isShared: true)
    let prompt = try await store.startPiAuth(providerId: "openai", method: "api_key")
    #expect(prompt.prompt?.type == "input")
    #expect(try await store.answerPiAuthFlow(id: prompt.id, value: "test-key").state == "complete")
    try await store.removePiAuthProvider(id: "openai")
    #expect(
      try HarnessSharedCredentials.pi.credentials(from: HarnessSharedCredentials.pi.content(in: environment.configSync))
        .isEmpty)
  }

  @Test("Shared OAuth and API key operations use the selected machine's shared-account endpoint")
  func sharedOAuth() async throws {
    let transport = SharedAccountTestTransport()
    let environment = AppEnvironment(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: AppSettingsModel(store: InMemoryStore()),
      machineClientFactory: { _ in
        CodevisorServerClient(config: .init(baseURL: URL(string: "http://fixture.test")!, requestTransport: transport))
      }
    )
    let store = HarnessAccountsStore(environment: environment, machineId: "local", isShared: true)
    let account = try await store.createHarnessAccount(harnessId: "codex", label: "Work")
    #expect(account.id == "shared-test")
    let flow = try await store.loginHarnessAccount(
      harnessId: "codex", accountId: account.id, methodId: "apiKey", apiKey: "fixture-key")
    #expect(flow.kind == "complete")
    #expect(try await store.probeHarnessAccount(harnessId: "codex", accountId: account.id).authState == "authenticated")
    #expect(try await store.activateHarnessAccount(harnessId: "codex", accountId: account.id).first?.isActive == true)
    #expect(
      try await store.renameHarnessAccount(harnessId: "codex", accountId: account.id, label: "Personal").label
        == "Personal")
    #expect(
      try await store.logoutHarnessAccount(harnessId: "codex", accountId: account.id).authState == "unauthenticated")
    let oauth = try await store.loginHarnessAccount(
      harnessId: "claude-code", accountId: account.id, methodId: "oauth", apiKey: nil)
    #expect(oauth.kind == "pasteCode")
    #expect(
      try await store.answerHarnessLogin(
        harnessId: "claude-code", accountId: account.id, flowId: oauth.id, code: "fixture-code"
      ).kind == "complete")
    try await store.cancelHarnessLogin(harnessId: "claude-code", accountId: account.id, flowId: oauth.id)
    try await store.useSharedHarnessAccount(harnessId: "codex")
    try await store.removeHarnessAccount(harnessId: "codex", accountId: account.id)
    let requests = await transport.requests
    #expect(requests.allSatisfy { $0.hasSuffix("/shared-accounts") })
    #expect(environment.configSync.value(namespace: HarnessSharedCredentials.namespace, key: "codex-auth-file") == nil)
  }
}

private actor ProviderAccountTestTransport: ServerRequestTransport {
  var paths: [String] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url!.path
    paths.append(path)
    let pi = path.contains("/pi/")
    let flow: [String: Any] = [
      "id": pi ? "native-pi" : "native-opencode", "accountId": "default", "providerId": pi ? "anthropic" : "openai",
      "state": "complete",
    ]
    let response: [String: Any]
    if path.hasSuffix("/shared-accounts") {
      let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      #expect(payload["action"] as? String == "login")
      #expect(payload["providerId"] as? String == (pi ? "anthropic" : "openai"))
      if !pi { #expect((payload["inputs"] as? [String: String])?["plan"] == "plus") }
      response = [pi ? "piFlow" : "openCodeFlow": flow]
    } else if path.contains("/auth-flows/") {
      response = flow
    } else {
      return (
        Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
      )
    }
    return (
      try JSONSerialization.data(withJSONObject: response),
      HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    )
  }
}

private actor SharedAccountTestTransport: ServerRequestTransport {
  var requests: [String] = []
  var label = "Work"
  var authenticated = false
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url!.path
    guard path.hasSuffix("/shared-accounts"), let body = request.httpBody else {
      return (
        Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
      )
    }
    requests.append(path)
    let payload = try JSONDecoder().decode([String: String].self, from: body)
    let action = payload["action"]!
    let oauth = payload["methodId"] == "oauth"
    let device = payload["methodId"] == "grok.com"
    if action == "rename" { label = payload["label"]! }
    if action == "answer" || (action == "login" && !oauth && !device) { authenticated = true }
    if action == "logout" { authenticated = false }
    let account: [String: Any] = [
      "id": "shared-test", "harnessId": path.split(separator: "/")[2].description,
      "label": label, "profileKind": "managed", "authState": authenticated ? "authenticated" : "unauthenticated",
      "isActive": true, "canLogin": true, "canLogout": authenticated, "selectionScope": "shared",
    ]
    let response: [String: Any] = [
      "account": account, "accounts": [account],
      "flow": [
        "id": "flow", "accountId": "shared-test", "kind": device ? "deviceCode" : (oauth ? "pasteCode" : "complete"),
        "userCode": "ABCD-EFGH", "verificationUrl": "https://auth.x.ai/device",
      ],
    ]
    return (
      try JSONSerialization.data(withJSONObject: response),
      HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    )
  }
}
