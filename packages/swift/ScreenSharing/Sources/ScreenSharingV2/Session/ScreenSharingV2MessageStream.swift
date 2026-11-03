import Foundation

public protocol ScreenSharingV2MessageStream: AnyObject, Sendable {
  func send(_ payload: Data) async throws
  func receive() async throws -> Data?
  func finish() async
}
