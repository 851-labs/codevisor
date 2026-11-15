import Foundation
import ScreenSharingConnection

public struct ComputerUseRemotePreviewSource {
  public typealias Connect =
    @MainActor (_ target: String, _ attachedPane: ScreenSharingLegacyIdentity, _ heartbeat: Duration) ->
    ScreenSharingConnection?

  public var machineName: String
  public var connection: Connect
  public var end: @MainActor (_ target: String) -> Void

  public init(machineName: String, connection: @escaping Connect, end: @escaping @MainActor (_ target: String) -> Void)
  {
    self.machineName = machineName
    self.connection = connection
    self.end = end
  }
}
