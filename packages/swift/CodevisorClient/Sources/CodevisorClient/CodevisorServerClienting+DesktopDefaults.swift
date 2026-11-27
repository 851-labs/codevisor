import Foundation

extension CodevisorServerClienting {
  public func desktopStatus() async throws -> ServerDesktopStatus {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  public func installDesktopPackages() async throws -> ServerDesktopStatus {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  public func replaceOldDesktop() async throws -> ServerDesktopStatus {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  public func startDesktop(replacingUnmanaged: Bool) async throws -> ServerDesktopStatus {
    throw CodevisorServerClientError.httpStatus(404, "")
  }

  public func removeDesktop(unsharingUnmanaged: Bool) async throws -> ServerDesktopStatus {
    throw CodevisorServerClientError.httpStatus(404, "")
  }
}
