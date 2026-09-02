import CodevisorCore

struct McpFormValues {
  var name: String
  var transport: String
  var location: String
  var arguments: [String]
  var authSelection: String
  var effectiveAuthType: String
  var bearerToken: String?
  var oauthScope: String?
  var oauthClientId: String?
  var oauthClientSecret: String?
  var headers: [String: String]
  var environment: [String: String]
  var removedHeaders: [String]
  var removedEnvironment: [String]

  var createBody: CreateMcpServerBody {
    CreateMcpServerBody(
      name: name,
      transport: transport,
      url: transport == "http" ? location : nil,
      command: transport == "stdio" ? location : nil,
      args: transport == "stdio" ? arguments : nil,
      env: transport == "stdio" && !environment.isEmpty ? environment : nil,
      headers: transport == "http" && !headers.isEmpty ? headers : nil,
      authType: transport == "http" ? (authSelection == "auto" ? nil : authSelection) : "none",
      bearerToken: transport == "http" ? bearerToken : nil,
      oauthScope: transport == "http" ? oauthScope : nil,
      oauthClientId: transport == "http" ? oauthClientId : nil,
      oauthClientSecret: transport == "http" ? oauthClientSecret : nil
    )
  }

  var updateBody: UpdateMcpServerBody {
    UpdateMcpServerBody(
      name: name,
      url: transport == "http" ? location : nil,
      command: transport == "stdio" ? location : nil,
      args: transport == "stdio" ? arguments : nil,
      env: transport == "stdio" && !environment.isEmpty ? environment : nil,
      headers: transport == "http" && !headers.isEmpty ? headers : nil,
      removeEnv: transport == "stdio" && !removedEnvironment.isEmpty ? removedEnvironment : nil,
      removeHeaders: transport == "http" && !removedHeaders.isEmpty ? removedHeaders : nil,
      authType: transport == "http" ? effectiveAuthType : "none",
      bearerToken: transport == "http" ? bearerToken : nil,
      oauthScope: transport == "http" ? oauthScope : nil,
      oauthClientId: transport == "http" ? oauthClientId : nil,
      oauthClientSecret: transport == "http" ? oauthClientSecret : nil
    )
  }
}
