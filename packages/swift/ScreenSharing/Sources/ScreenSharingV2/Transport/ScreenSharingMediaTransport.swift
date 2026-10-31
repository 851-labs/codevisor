import Foundation

public protocol ScreenSharingMediaTransport: AnyObject, Sendable {
  func send(_ tile: ScreenSharingEncodedTile, meta: Data) throws
  func admission() -> ScreenSharingMediaAdmission
  func nextEvent() async -> ScreenSharingMediaEvent?
  func acknowledge(ltrToken: UInt64, stream: UInt8)
  var roundTripUs: UInt64 { get }
  func close()
}
