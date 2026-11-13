import Foundation

public struct ServerFirstRunHarness: Codable, Equatable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct ServerFirstRunProject: Codable, Equatable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct ServerFirstRunFolder: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var path: String
  public var projects: [String]

  public init(id: String, name: String, path: String, projects: [String]) {
    self.id = id
    self.name = name
    self.path = path
    self.projects = projects
  }
}

public struct ServerFirstRunFolderAnswer: Codable, Equatable, Sendable {
  public enum Access: String, Codable, Sendable {
    case allow
    case decline
  }

  public var access: Access

  public init(access: Access) {
    self.access = access
  }
}

public struct ServerFirstRunStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case notApplicable
    case running
    case done
    case failed
  }

  public static let eventKind = "firstRun.updated"
  public static let eventSubject = "first-run"

  public var state: State
  public var harnesses: [ServerFirstRunHarness]?
  public var projects: [ServerFirstRunProject]?
  public var folders: [ServerFirstRunFolder]?

  public init(
    state: State,
    harnesses: [ServerFirstRunHarness]? = nil,
    projects: [ServerFirstRunProject]? = nil,
    folders: [ServerFirstRunFolder]? = nil
  ) {
    self.state = state
    self.harnesses = harnesses
    self.projects = projects
    self.folders = folders
  }

  public var isFinal: Bool { state != .running }

  public var foldersToAsk: [ServerFirstRunFolder] { folders ?? [] }

  public var isNewInstall: Bool { state == .running || state == .failed || harnesses != nil }

  public static func from(_ envelope: ServerEventEnvelope) -> ServerFirstRunStatus? {
    guard envelope.kind == eventKind, let data = try? JSONEncoder().encode(envelope.payload) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

extension CodevisorServerClient {
  public func firstRunStatus() async throws -> ServerFirstRunStatus {
    try await get("/v1/first-run")
  }

  public func answerFirstRunFolder(
    id: String, access: ServerFirstRunFolderAnswer.Access
  ) async throws -> ServerFirstRunStatus {
    let folder = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    return try await send(
      "/v1/first-run/folders/\(folder)", method: "POST", body: ServerFirstRunFolderAnswer(access: access))
  }
}

public extension CodevisorServerClienting {
  func firstRunStatus() async throws -> ServerFirstRunStatus {
    throw CodevisorServerClientError.invalidResponse
  }

  func answerFirstRunFolder(
    id: String, access: ServerFirstRunFolderAnswer.Access
  ) async throws -> ServerFirstRunStatus {
    throw CodevisorServerClientError.invalidResponse
  }
}
