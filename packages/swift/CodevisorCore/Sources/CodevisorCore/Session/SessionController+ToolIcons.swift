import Foundation

extension SessionController {
  public func toolIconData(_ request: ServerToolIconRequest) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    return try await serverClient.toolIcon(request)
  }

  public var toolIconCacheNamespace: String { "\(project.serverId)" }
}
