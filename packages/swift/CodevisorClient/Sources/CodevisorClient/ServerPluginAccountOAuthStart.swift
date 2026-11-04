import Foundation

public struct ServerPluginAccountOAuthStart: Codable, Equatable, Sendable {
  public var flowId: String
  public var authorizationUrl: String
  public var callbackScheme: String?

  public init(flowId: String, authorizationUrl: String, callbackScheme: String? = nil) {
    self.flowId = flowId
    self.authorizationUrl = authorizationUrl
    self.callbackScheme = callbackScheme
  }
}
