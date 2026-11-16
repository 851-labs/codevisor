import Foundation
import ScreenSharingConnection

public struct ComputerUseRemotePreviewSource {
  public typealias Connect = @MainActor (_ target: String, _ heartbeat: Duration) -> ScreenSharingConnection?
  public typealias IsActive = @MainActor (_ target: String) async -> Bool?

  public var machineName: String
  public var connection: Connect
  public var isActive: IsActive
  public var end: @MainActor (_ target: String) -> Void

  public init(
    machineName: String, connection: @escaping Connect, isActive: @escaping IsActive,
    end: @escaping @MainActor (_ target: String) -> Void
  ) {
    self.machineName = machineName
    self.connection = connection
    self.isActive = isActive
    self.end = end
  }
}
