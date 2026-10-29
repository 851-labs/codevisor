import CodevisorCore
import Foundation
import Observation

@MainActor @Observable
public final class McpServerDraft {
  public enum Field: Hashable, Sendable {
    case location, authorization, bearerToken, oauthScope, oauthClient, secrets
  }

  public struct Actions {
    let save: (UpdateMcpServerBody) async throws -> ServerMcpServer
    let recordConsent: (CustomPluginLocation) async throws -> Void

    public init(
      save: @escaping (UpdateMcpServerBody) async throws -> ServerMcpServer,
      recordConsent: @escaping (CustomPluginLocation) async throws -> Void
    ) {
      self.save = save
      self.recordConsent = recordConsent
    }
  }

  public private(set) var server: ServerMcpServer
  public var location: String
  public var authType: String
  public var bearerToken = ""
  public var oauthScope: String
  public var clientId = ""
  public var clientSecret = ""
  public var secrets: [McpSecretEntry]
  public private(set) var errors: [Field: String] = [:]
  public private(set) var saving: Field?

  public init(server: ServerMcpServer) {
    self.server = server
    location = Self.location(of: server)
    authType = server.authType
    oauthScope = server.oauthScope ?? ""
    secrets = Self.secrets(of: server)
  }

  public var isHTTP: Bool { server.transport == "http" }

  public var awaitsBearerToken: Bool { authType == "bearer" && server.authType != "bearer" }

  public var needsConsent: Bool {
    guard let candidate = try? candidateLocation() else { return false }
    return candidate
      != CustomPluginLocation(
        transport: server.transport, url: server.url, command: server.command, args: server.args)
  }

  public func refresh(from updated: ServerMcpServer) {
    let previous = server
    server = updated
    if location == Self.location(of: previous) { location = Self.location(of: updated) }
    if authType == previous.authType { authType = updated.authType }
    if oauthScope == (previous.oauthScope ?? "") { oauthScope = updated.oauthScope ?? "" }
    if !McpSecretChanges(entries: secrets, savedNames: Self.secretNames(of: previous)).hasChanges {
      secrets = Self.secrets(of: updated)
    }
  }

  public func commitLocation(using actions: Actions) async {
    guard location.trimmingCharacters(in: .whitespacesAndNewlines) != Self.location(of: server) else {
      errors[.location] = nil
      return
    }

    do {
      let body = try locationBody()
      let consent = needsConsent ? try candidateLocation() : nil
      await run(.location, using: actions) {
        if let consent { try await actions.recordConsent(consent) }
        return body
      }
    } catch {
      errors[.location] = error.localizedDescription
    }
  }

  public func selectAuthorization(_ type: String, using actions: Actions) async {
    authType = type
    guard type != server.authType else { return }
    guard !awaitsBearerToken else {
      errors[.bearerToken] = "Enter a token to use bearer authorization."
      return
    }

    await run(.authorization, using: actions) { UpdateMcpServerBody(authType: type) }
  }

  public func commitBearerToken(using actions: Actions) async {
    guard !bearerToken.isEmpty else { return }

    await run(.bearerToken, using: actions) { UpdateMcpServerBody(authType: "bearer", bearerToken: self.bearerToken) }
  }

  public func commitOAuthScope(using actions: Actions) async {
    guard oauthScope != (server.oauthScope ?? "") else { return }

    await run(.oauthScope, using: actions) { UpdateMcpServerBody(oauthScope: self.oauthScope) }
  }

  public func commitOAuthClient(using actions: Actions) async {
    guard !clientId.isEmpty || !clientSecret.isEmpty else { return }

    await run(.oauthClient, using: actions) {
      UpdateMcpServerBody(
        oauthClientId: self.clientId.isEmpty ? nil : self.clientId,
        oauthClientSecret: self.clientSecret.isEmpty ? nil : self.clientSecret)
    }
  }

  public func commitSecrets(using actions: Actions) async {
    let changes = McpSecretChanges(entries: secrets, savedNames: Self.secretNames(of: server))
    if let problem = changes.problem {
      errors[.secrets] = problem
      return
    }
    guard changes.hasChanges else {
      errors[.secrets] = nil
      return
    }

    await run(.secrets, using: actions) { changes.body(isHTTP: self.isHTTP) }
  }

  private func run(
    _ field: Field, using actions: Actions, body: () async throws -> UpdateMcpServerBody
  ) async {
    saving = field
    defer { saving = nil }
    do {
      let updated = try await actions.save(try await body())
      errors[field] = nil
      apply(updated, after: field)
    } catch {
      errors[field] = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func apply(_ updated: ServerMcpServer, after field: Field) {
    server = updated
    switch field {
    case .location: location = Self.location(of: updated)
    case .authorization: authType = updated.authType
    case .bearerToken:
      bearerToken = ""
      authType = updated.authType
      errors[.bearerToken] = nil
    case .oauthScope: oauthScope = updated.oauthScope ?? ""
    case .oauthClient:
      clientId = ""
      clientSecret = ""
    case .secrets: secrets = Self.secrets(of: updated)
    }
  }

  private func locationBody() throws -> UpdateMcpServerBody {
    let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
    if isHTTP {
      guard Self.isWebURL(trimmed) else { throw McpDraftError.invalidURL }
      return UpdateMcpServerBody(url: trimmed)
    }
    let components = try CommandLineCodec.parse(trimmed)
    guard let command = components.first else { throw McpDraftError.missingCommand }
    return UpdateMcpServerBody(command: command, args: Array(components.dropFirst()))
  }

  private func candidateLocation() throws -> CustomPluginLocation {
    let body = try locationBody()
    return CustomPluginLocation(
      transport: server.transport, url: body.url, command: body.command, args: body.args ?? [])
  }

  private static func isWebURL(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host() != nil
  }

  private static func location(of server: ServerMcpServer) -> String {
    server.url ?? CommandLineCodec.format([server.command].compactMap { $0 } + server.args)
  }

  private static func secretNames(of server: ServerMcpServer) -> [String] {
    (server.transport == "http" ? server.headerNames : server.environmentNames) ?? []
  }

  private static func secrets(of server: ServerMcpServer) -> [McpSecretEntry] {
    secretNames(of: server).sorted().map { McpSecretEntry(name: $0, value: "", existing: true) }
  }
}

enum McpDraftError: LocalizedError {
  case invalidURL
  case missingCommand

  var errorDescription: String? {
    switch self {
    case .invalidURL: "Enter an http or https URL."
    case .missingCommand: "Enter a command to run."
    }
  }
}
