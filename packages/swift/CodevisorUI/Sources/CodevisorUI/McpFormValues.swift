import CodevisorCore

public struct McpFormValues {
  public var name: String
  public var transport: String
  public var location: String
  public var arguments: [String]
  public var authSelection: String
  public var effectiveAuthType: String
  public var bearerToken: String?
  public var oauthScope: String?
  public var oauthClientId: String?
  public var oauthClientSecret: String?
  public var headers: [String: String]
  public var environment: [String: String]

  public init(
    name: String,
    transport: String,
    location: String,
    arguments: [String],
    authSelection: String,
    effectiveAuthType: String,
    bearerToken: String?,
    oauthScope: String?,
    oauthClientId: String?,
    oauthClientSecret: String?,
    headers: [String: String],
    environment: [String: String]
  ) {
    self.name = name
    self.transport = transport
    self.location = location
    self.arguments = arguments
    self.authSelection = authSelection
    self.effectiveAuthType = effectiveAuthType
    self.bearerToken = bearerToken
    self.oauthScope = oauthScope
    self.oauthClientId = oauthClientId
    self.oauthClientSecret = oauthClientSecret
    self.headers = headers
    self.environment = environment
  }

  public var customLocation: CustomPluginLocation {
    CustomPluginLocation(
      transport: transport,
      url: transport == "http" ? location : nil,
      command: transport == "stdio" ? location : nil,
      args: transport == "stdio" ? arguments : [])
  }

  public var createBody: CreateMcpServerBody {
    CreateMcpServerBody(
      name: name,
      transport: transport,
      url: transport == "http" ? location : nil,
      command: transport == "stdio" ? location : nil,
      args: transport == "stdio" ? arguments : nil,
      env: transport == "stdio" && !environment.isEmpty ? environment : nil,
      headers: transport == "http" && !headers.isEmpty ? headers : nil,
      authType: createAuthType,
      bearerToken: transport == "http" ? bearerToken : nil,
      oauthScope: transport == "http" ? oauthScope : nil,
      oauthClientId: transport == "http" ? oauthClientId : nil,
      oauthClientSecret: transport == "http" ? oauthClientSecret : nil
    )
  }

  private var createAuthType: String? {
    guard transport == "http" else { return "none" }
    return authSelection == "auto" ? nil : authSelection
  }
}
