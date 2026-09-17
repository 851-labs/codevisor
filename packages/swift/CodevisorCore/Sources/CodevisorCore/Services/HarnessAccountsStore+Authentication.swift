import ACPKit
import Foundation

public extension HarnessAccountsStore {
  func loginHarnessAccount(
    harnessId: String, accountId: String, methodId: String?, apiKey: String?
  ) async throws -> ServerHarnessAuthFlow {
    if usesSharedOAuth(harnessId) {
      guard
        let flow = try await shared(
          harnessId, .init(action: "login", accountId: accountId, methodId: methodId, apiKey: apiKey)
        ).flow
      else { throw CodevisorServerClientError.invalidResponse }
      return flow
    }
    guard isShared else {
      return try await client.loginHarnessAccount(
        harnessId: harnessId, accountId: accountId, methodId: methodId, apiKey: apiKey)
    }
    guard let source = HarnessSharedCredentials(rawValue: harnessId), let apiKey else {
      throw CodevisorServerClientError.invalidResponse
    }
    let updated = try source.replacingKey(in: source.content(in: sync), providerId: "openai", key: apiKey)
    sync.set(namespace: Self.namespace, key: source.sourceKey, value: .string(updated))
    return try decoded(
      ServerHarnessAuthFlow.self,
      ["id": .string(UUID().uuidString), "accountId": .string(accountId), "kind": .string("complete")])
  }

  func logoutHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
    if usesSharedOAuth(harnessId) {
      guard let account = try await shared(harnessId, .init(action: "logout", accountId: accountId)).account else {
        throw CodevisorServerClientError.invalidResponse
      }
      return account
    }
    guard isShared else { return try await client.logoutHarnessAccount(harnessId: harnessId, accountId: accountId) }
    guard let source = HarnessSharedCredentials(rawValue: harnessId) else {
      throw CodevisorServerClientError.invalidResponse
    }
    sync.remove(namespace: Self.namespace, key: source.sourceKey)
    guard let account = try await listHarnessAccounts(harnessId: harnessId).first else {
      throw CodevisorServerClientError.invalidResponse
    }
    return account
  }

  func probeHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
    if usesSharedOAuth(harnessId) {
      guard let account = try await shared(harnessId, .init(action: "probe", accountId: accountId)).account else {
        throw CodevisorServerClientError.invalidResponse
      }
      return account
    }
    guard isShared else { return try await client.probeHarnessAccount(harnessId: harnessId, accountId: accountId) }
    guard let account = try await listHarnessAccounts(harnessId: harnessId).first(where: { $0.id == accountId }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    return account
  }

  func answerHarnessLogin(
    harnessId: String, accountId: String, flowId: String, code: String
  ) async throws -> ServerHarnessAuthFlow {
    if usesSharedOAuth(harnessId) {
      guard
        let flow = try await shared(
          harnessId, .init(action: "answer", accountId: accountId, flowId: flowId, code: code)
        ).flow
      else { throw CodevisorServerClientError.invalidResponse }
      return flow
    }
    return try await client.answerHarnessLogin(harnessId: harnessId, accountId: accountId, flowId: flowId, code: code)
  }

  func cancelHarnessLogin(harnessId: String, accountId: String, flowId: String) async throws {
    if usesSharedOAuth(harnessId) {
      _ = try await shared(harnessId, .init(action: "cancel", accountId: accountId, flowId: flowId)); return
    }
    if !isShared { try await client.cancelHarnessLogin(harnessId: harnessId, accountId: accountId, flowId: flowId) }
  }

  func useSharedHarnessAccount(harnessId: String) async throws {
    _ = try await shared(harnessId, .init(action: "inherit"))
  }
}
