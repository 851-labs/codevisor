import CodevisorClient
import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
public enum ScreenSharingViewerMedia {
  static var connector: ScreenSharingV2Connector { .live(connectLocally: connectLocally) }

  public static func connectLocally(_ token: String) -> (any ScreenSharingV2Connection)? {
    ScreenSharingV2Acceptor.shared.connectLocally(token: token)
  }
}
