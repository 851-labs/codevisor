import Foundation

public protocol ScreenSharingMediaTransport: AnyObject, Sendable {
  @discardableResult func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws -> UInt32
  func admission() -> ScreenSharingMediaAdmission
  func nextEvent() async -> ScreenSharingMediaEvent?
  func acknowledge(ltrToken: UInt64, stream: UInt8)
  func requestRefresh(stream: UInt8, keyframe: Bool)
  var roundTripUs: UInt64 { get }
  var lossRate: Double { get }
  func close()
  func sendDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) -> Bool
}

extension ScreenSharingMediaTransport {
  public func sendDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) -> Bool { false }
}
