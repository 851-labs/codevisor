import CodevisorClient
import ComposableArchitecture
import Foundation
import os

public struct MachineDesktopClient: Sendable {
  public var status: @Sendable () async throws -> ServerDesktopStatus
  public var installPackages: @Sendable () async throws -> ServerDesktopStatus
  public var replaceOld: @Sendable () async throws -> ServerDesktopStatus
  public var start: @Sendable (_ replacingUnmanaged: Bool) async throws -> ServerDesktopStatus
  public var remove: @Sendable (_ unsharingUnmanaged: Bool) async throws -> ServerDesktopStatus

  public init(
    status: @escaping @Sendable () async throws -> ServerDesktopStatus,
    installPackages: @escaping @Sendable () async throws -> ServerDesktopStatus,
    replaceOld: @escaping @Sendable () async throws -> ServerDesktopStatus,
    start: @escaping @Sendable (_ replacingUnmanaged: Bool) async throws -> ServerDesktopStatus,
    remove: @escaping @Sendable (_ unsharingUnmanaged: Bool) async throws -> ServerDesktopStatus
  ) {
    self.status = status
    self.installPackages = installPackages
    self.replaceOld = replaceOld
    self.start = start
    self.remove = remove
  }
}

extension MachineDesktopClient: TestDependencyKey {
  public static var testValue: Self {
    Self(
      status: { throw Unimplemented() }, installPackages: { throw Unimplemented() },
      replaceOld: { throw Unimplemented() }, start: { _ in throw Unimplemented() },
      remove: { _ in throw Unimplemented() })
  }

  private struct Unimplemented: Error {}
}

extension MachineDesktopClient {
  public static func live(_ server: @escaping @Sendable () async -> any CodevisorServerClienting) -> Self {
    Self(
      status: { try await logged("status") { try await server().desktopStatus() } },
      installPackages: { try await logged("install") { try await server().installDesktopPackages() } },
      replaceOld: { try await logged("replace-old") { try await server().replaceOldDesktop() } },
      start: { replacing in
        try await logged("start") { try await server().startDesktop(replacingUnmanaged: replacing) }
      },
      remove: { unsharing in
        try await logged("remove") { try await server().removeDesktop(unsharingUnmanaged: unsharing) }
      })
  }

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "MachineDesktop")

  private static func logged(
    _ call: String, _ work: () async throws -> ServerDesktopStatus
  ) async throws -> ServerDesktopStatus {
    do {
      let status = try await work()
      if let problem = status.problem {
        logger.notice("Desktop \(call, privacy: .public): \(problem, privacy: .public)")
      }
      if let failure = status.failure {
        logger.error("Desktop \(call, privacy: .public) install failed: \(failure, privacy: .public)")
      }
      return status
    } catch {
      logger.error("Desktop \(call, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      throw error
    }
  }
}
