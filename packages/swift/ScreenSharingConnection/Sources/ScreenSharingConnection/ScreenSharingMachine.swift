import Foundation
import ScreenSharingV2

public struct ScreenSharingMachine {
  public typealias MakeVNCTransport =
    @MainActor (_ displayId: String, _ arbitratedByServer: Bool) -> any ScreenSharingTransport

  public struct Signer: Sendable {
    public var key: String
    public var sign: @Sendable (Data) throws -> Data

    public init(key: String, sign: @escaping @Sendable (Data) throws -> Data) {
      self.key = key
      self.sign = sign
    }
  }

  public let id: String
  public var channel: @MainActor () -> any ScreenSharingHostChannel
  public var connector: ScreenSharingV2Connector
  public var appName: String
  public var signer: Signer
  public var installId: UUID
  public var liveWorkspace: @MainActor () -> UUID?
  public var presentsTiles: Bool
  public var makeVNCTransport: MakeVNCTransport?

  public init(
    id: String, channel: @escaping @MainActor () -> any ScreenSharingHostChannel, connector: ScreenSharingV2Connector,
    appName: String, signer: Signer, installId: UUID, liveWorkspace: @escaping @MainActor () -> UUID?,
    presentsTiles: Bool = false, makeVNCTransport: MakeVNCTransport? = nil
  ) {
    self.id = id
    self.channel = channel
    self.connector = connector
    self.appName = appName
    self.signer = signer
    self.installId = installId
    self.liveWorkspace = liveWorkspace
    self.presentsTiles = presentsTiles
    self.makeVNCTransport = makeVNCTransport
  }
}
