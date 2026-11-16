import Foundation
import ScreenSharingConnection

public struct SimulatorStreamSource {
  public typealias Connect = @MainActor (_ target: String) -> ScreenSharingConnection?

  public var machineName: String
  public var connection: Connect
  public var end: @MainActor (_ target: String) -> Void

  public init(machineName: String, connection: @escaping Connect, end: @escaping @MainActor (_ target: String) -> Void)
  {
    self.machineName = machineName
    self.connection = connection
    self.end = end
  }

  public static func target(udid: String) -> String { "simulator:\(udid)" }
}
