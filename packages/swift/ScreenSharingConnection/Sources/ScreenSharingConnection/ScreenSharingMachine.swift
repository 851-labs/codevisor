import Foundation
import ScreenSharingV2

public struct ScreenSharingMachine {
  public typealias MakeVNCTransport =
    @MainActor (_ displayId: String, _ arbitratedByServer: Bool) -> any ScreenSharingTransport

  public let id: String
  public var channel: any ScreenSharingHostChannel
  public var connector: ScreenSharingV2Connector
  public var appName: String
  public var installId: UUID
  public var liveWorkspace: @MainActor () -> UUID?
  public var presentsTiles: Bool
  public var makeVNCTransport: MakeVNCTransport?

  public init(
    id: String, channel: any ScreenSharingHostChannel, connector: ScreenSharingV2Connector, appName: String,
    installId: UUID, liveWorkspace: @escaping @MainActor () -> UUID?, presentsTiles: Bool = false,
    makeVNCTransport: MakeVNCTransport? = nil
  ) {
    self.id = id
    self.channel = channel
    self.connector = connector
    self.appName = appName
    self.installId = installId
    self.liveWorkspace = liveWorkspace
    self.presentsTiles = presentsTiles
    self.makeVNCTransport = makeVNCTransport
  }
}
