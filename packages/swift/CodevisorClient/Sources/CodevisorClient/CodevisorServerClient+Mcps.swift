import ACPKit
import CodevisorProtocol
import Foundation

public struct CreateMcpServerBody: Encodable, Equatable, Sendable {
  public var name: String
  public var transport: String
  public var url: String?
  public var command: String?
  public var args: [String]?
  public var env: [String: String]?
  public var headers: [String: String]?
  public var enabled: Bool?
  public var authType: String?
  public var bearerToken: String?
  public var oauthScope: String?
  public var oauthClientId: String?
  public var oauthClientSecret: String?

  public init(
    name: String,
    transport: String,
    url: String? = nil,
    command: String? = nil,
    args: [String]? = nil,
    env: [String: String]? = nil,
    headers: [String: String]? = nil,
    enabled: Bool? = true,
    authType: String? = nil,
    bearerToken: String? = nil,
    oauthScope: String? = nil,
    oauthClientId: String? = nil,
    oauthClientSecret: String? = nil
  ) {
    self.name = name
    self.transport = transport
    self.url = url
    self.command = command
    self.args = args
    self.env = env
    self.headers = headers
    self.enabled = enabled
    self.authType = authType
    self.bearerToken = bearerToken
    self.oauthScope = oauthScope
    self.oauthClientId = oauthClientId
    self.oauthClientSecret = oauthClientSecret
  }
}

public struct UpdateMcpServerBody: Encodable, Equatable, Sendable {
  public var name: String?
  public var url: String?
  public var command: String?
  public var args: [String]?
  public var env: [String: String]?
  public var headers: [String: String]?
  public var removeEnv: [String]?
  public var removeHeaders: [String]?
  public var authType: String?
  public var bearerToken: String?
  public var oauthScope: String?
  public var oauthClientId: String?
  public var oauthClientSecret: String?

  public init(
    name: String? = nil,
    url: String? = nil,
    command: String? = nil,
    args: [String]? = nil,
    env: [String: String]? = nil,
    headers: [String: String]? = nil,
    removeEnv: [String]? = nil,
    removeHeaders: [String]? = nil,
    authType: String? = nil,
    bearerToken: String? = nil,
    oauthScope: String? = nil,
    oauthClientId: String? = nil,
    oauthClientSecret: String? = nil
  ) {
    self.name = name
    self.url = url
    self.command = command
    self.args = args
    self.env = env
    self.headers = headers
    self.removeEnv = removeEnv
    self.removeHeaders = removeHeaders
    self.authType = authType
    self.bearerToken = bearerToken
    self.oauthScope = oauthScope
    self.oauthClientId = oauthClientId
    self.oauthClientSecret = oauthClientSecret
  }
}

private struct UpdateMcpEnabledBody: Encodable {
  var enabled: Bool
}

private struct DetectMcpAuthBody: Encodable {
  var url: String
}

extension CodevisorServerClient {
  public func listMcpServers() async throws -> [ServerMcpServer] {
    try await get("/v1/mcps")
  }

  public func browserUseConfiguration() async throws -> ServerBrowserUseConfiguration {
    try await get("/v1/browser-use")
  }

  public func installDevelopmentBrowserExtension() async throws -> ServerBrowserUseConfiguration {
    try await send(
      "/v1/browser-use/extension/install",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func openBrowserExtensionFolder() async throws -> ServerBrowserUseConfiguration {
    try await send(
      "/v1/browser-use/extension/folder",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func openBrowserExtensionsPage() async throws -> ServerBrowserUseConfiguration {
    try await send(
      "/v1/browser-use/extension/chrome",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func openBrowserExtensionWebStore() async throws -> ServerBrowserUseConfiguration {
    try await send(
      "/v1/browser-use/extension/web-store",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func browserExtensionArchive() async throws -> URL {
    let data = try await performRaw(
      "/v1/browser-use/extension/archive",
      method: "GET",
      body: nil,
      contentType: nil
    )
    return try writeBrowserExtensionDownload(data, filename: "Codevisor Chrome Extension.zip")
  }

  public func browserExtensionIcon() async throws -> URL {
    let data = try await performRaw(
      "/v1/browser-use/extension/icon",
      method: "GET",
      body: nil,
      contentType: nil
    )
    return try writeBrowserExtensionDownload(data, filename: "Codevisor Browser Extension.png")
  }

  private func writeBrowserExtensionDownload(_ data: Data, filename: String) throws -> URL {
    let port = config.baseURL.port.map(String.init) ?? "default"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Codevisor Browser Extension-\(port)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent(filename)
    try data.write(to: fileURL, options: .atomic)
    return fileURL
  }

  public func detectMcpAuth(url: String) async throws -> ServerMcpAuthDetection {
    try await send(
      "/v1/mcps/detect-auth",
      method: "POST",
      body: DetectMcpAuthBody(url: url)
    )
  }

  public func createMcpServer(_ request: CreateMcpServerBody) async throws -> ServerMcpServer {
    try await send("/v1/mcps", method: "POST", body: request)
  }

  public func updateMcpServer(id: String, request: UpdateMcpServerBody) async throws -> ServerMcpServer {
    try await send("/v1/mcps/\(pathComponent(id))", method: "PATCH", body: request)
  }

  public func setMcpServerEnabled(id: String, enabled: Bool) async throws -> ServerMcpServer {
    try await send(
      "/v1/mcps/\(pathComponent(id))",
      method: "PATCH",
      body: UpdateMcpEnabledBody(enabled: enabled)
    )
  }

  public func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart {
    try await send(
      "/v1/mcps/\(pathComponent(id))/oauth-start",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func disconnectMcpOAuth(id: String) async throws -> ServerMcpServer {
    try await send(
      "/v1/mcps/\(pathComponent(id))/oauth-disconnect",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func removeMcpServer(id: String) async throws {
    try await sendNoResponse("/v1/mcps/\(pathComponent(id))", method: "DELETE")
  }

  public func listMcpTools(id: String) async throws -> [ServerMcpTool] {
    try await get("/v1/mcps/\(pathComponent(id))/tools")
  }
}
