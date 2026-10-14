import Foundation
import Observation

public enum LocalCodevisorServerState: Equatable, Sendable {
  case idle
  case alreadyRunning
  case started
  case unavailable(String)
}

public struct LocalDataUpgradeProgress: Codable, Equatable, Sendable {
  public var state: String
  public var id: String
  public var name: String
  public var completed: Int
  public var total: Int
  public var error: String?
  public var bootId: String?
  public var pid: Int?
  public var updatedAt: String?

  public init(
    state: String,
    id: String,
    name: String,
    completed: Int,
    total: Int,
    error: String? = nil,
    bootId: String? = nil,
    pid: Int? = nil,
    updatedAt: String? = nil
  ) {
    self.state = state
    self.id = id
    self.name = name
    self.completed = completed
    self.total = total
    self.error = error
    self.bootId = bootId
    self.pid = pid
    self.updatedAt = updatedAt
  }

  public var fractionCompleted: Double? {
    guard total > 0 else { return nil }
    return min(1, max(0, Double(completed) / Double(total)))
  }
}

public struct LocalCodevisorManagedService {
  public var prepare: @MainActor () async throws -> Void
  public var start: @MainActor () async throws -> Void
  public var stop: @MainActor () async throws -> Void
  public var isJobRunning: @MainActor () async -> Bool?

  public init(
    prepare: @escaping @MainActor () async throws -> Void = {},
    start: @escaping @MainActor () async throws -> Void,
    stop: @escaping @MainActor () async throws -> Void,
    isJobRunning: @escaping @MainActor () async -> Bool? = { nil }
  ) {
    self.prepare = prepare
    self.start = start
    self.stop = stop
    self.isJobRunning = isJobRunning
  }
}

@MainActor
public protocol LocalServerControlling: AnyObject, Observable {
  var state: LocalCodevisorServerState { get }
  var dataUpgradeProgress: LocalDataUpgradeProgress? { get }
  var startupProgress: LocalServerStartupProgress? { get }
  var onUpdateRequested: (@MainActor () -> Void)? { get set }

  func configureManagedService(_ service: LocalCodevisorManagedService)
  @discardableResult
  func ensureRunning() async -> LocalCodevisorServerState
  func prepareForAppUpdate(onStatus: @escaping @MainActor (String) -> Void) async -> Bool
  func abandonAppUpdate() async
  func shutdown() async -> Bool
}
