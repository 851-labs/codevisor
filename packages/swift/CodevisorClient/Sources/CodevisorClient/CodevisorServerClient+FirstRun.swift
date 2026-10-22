import Foundation

public struct ServerFirstRunHarness: Codable, Equatable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
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
  public var addedProjects: Int?

  public init(state: State, harnesses: [ServerFirstRunHarness]? = nil, addedProjects: Int? = nil) {
    self.state = state
    self.harnesses = harnesses
    self.addedProjects = addedProjects
  }

  public var isFinal: Bool { state != .running }

  public static func from(_ envelope: ServerEventEnvelope) -> ServerFirstRunStatus? {
    guard envelope.kind == eventKind, let data = try? JSONEncoder().encode(envelope.payload) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

extension CodevisorServerClient {
  public func firstRunStatus() async throws -> ServerFirstRunStatus {
    try await get("/v1/first-run")
  }
}

public extension CodevisorServerClienting {
  func firstRunStatus() async throws -> ServerFirstRunStatus {
    throw CodevisorServerClientError.invalidResponse
  }
}
