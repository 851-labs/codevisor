import CodevisorClient
import ComposableArchitecture
import Foundation

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
      status: { try await server().desktopStatus() },
      installPackages: { try await server().installDesktopPackages() },
      replaceOld: { try await server().replaceOldDesktop() },
      start: { try await server().startDesktop(replacingUnmanaged: $0) },
      remove: { try await server().removeDesktop(unsharingUnmanaged: $0) })
  }
}
