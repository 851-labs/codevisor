import Foundation

extension CodevisorServerClient {
  private static let desktopStartTimeout: TimeInterval = 150

  public func desktopStatus() async throws -> ServerDesktopStatus {
    try await get("/v1/desktop")
  }

  public func installDesktopPackages() async throws -> ServerDesktopStatus {
    try await desktopChange("POST", "/packages")
  }

  public func replaceOldDesktop() async throws -> ServerDesktopStatus {
    try await desktopChange("POST", "/replace-old")
  }

  public func startDesktop(replacingUnmanaged: Bool) async throws -> ServerDesktopStatus {
    try await desktopChange("POST", replacingUnmanaged ? "/start?replace=1" : "/start")
  }

  public func removeDesktop(unsharingUnmanaged: Bool) async throws -> ServerDesktopStatus {
    try await desktopChange("DELETE", unsharingUnmanaged ? "?unshare=1" : "")
  }

  private func desktopChange(_ method: String, _ path: String) async throws -> ServerDesktopStatus {
    try await send(
      "/v1/desktop\(path)", method: method, body: EmptyBody?.none, timeout: Self.desktopStartTimeout)
  }
}
