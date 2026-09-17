import Foundation

public struct ServerSharedHarnessAccountRequest: Encodable, Sendable {
  public var action: String
  public var accountId: String?
  public var label: String?
  public var methodId: String?
  public var apiKey: String?
  public var flowId: String?
  public var code: String?
  public var providerId: String?
  public var inputs: [String: String]?

  public init(
    action: String, accountId: String? = nil, label: String? = nil,
    methodId: String? = nil, apiKey: String? = nil, flowId: String? = nil, code: String? = nil,
    providerId: String? = nil, inputs: [String: String]? = nil
  ) {
    self.action = action
    self.accountId = accountId
    self.label = label
    self.methodId = methodId
    self.apiKey = apiKey
    self.flowId = flowId
    self.code = code
    self.providerId = providerId
    self.inputs = inputs
  }
}

public struct ServerSharedHarnessAccountResponse: Decodable, Sendable {
  public var accounts: [ServerHarnessAccount]?
  public var account: ServerHarnessAccount?
  public var flow: ServerHarnessAuthFlow?
  public var piProviders: [ServerPiAuthProvider]?
  public var openCodeProviders: [ServerOpenCodeAuthProvider]?
  public var piFlow: ServerPiAuthFlow?
  public var openCodeFlow: ServerOpenCodeAuthFlow?
}

extension CodevisorServerClient {
  public func sharedHarnessAccount(
    harnessId: String, request: ServerSharedHarnessAccountRequest
  ) async throws
    -> ServerSharedHarnessAccountResponse
  {
    try await send("/v1/harnesses/\(pathComponent(harnessId))/shared-accounts", method: "POST", body: request)
  }
}
