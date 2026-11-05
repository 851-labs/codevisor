import CodevisorClient
import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
public enum ScreenSharingViewerMedia {
  static var connector: ScreenSharingV2Connector { .live(connectLocally: connectLocally) }

  public static func address() async -> ServerScreenSharingMediaAddress? {
    await ScreenSharingMediaEndpoint.shared.viewerAddress()
  }

  public static func connect(to grant: ServerScreenSharingMediaGrant) async throws -> any ScreenSharingSimulatorSession
  {
    try await ScreenSharingMediaEndpoint.shared.connectViewer(to: grant, locally: connectLocally)
  }

  private static func connectLocally(_ token: String) -> (any ScreenSharingV2Connection)? {
    ScreenSharingV2Acceptor.shared.connectLocally(token: token)
  }
}
