import Foundation

public struct ScreenSharingV2Route: Equatable, Sendable {
  public let isRelay: Bool
  public let roundTripMs: Double

  public init(isRelay: Bool, roundTripMs: Double) {
    self.isRelay = isRelay
    self.roundTripMs = roundTripMs
  }
}

public protocol ScreenSharingV2Connection: AnyObject, Sendable {
  var remoteId: String { get }
  var route: ScreenSharingV2Route? { get }
  func openStream() async throws -> any ScreenSharingV2MessageStream
  func acceptStream() async throws -> any ScreenSharingV2MessageStream
  func openMedia() async -> any ScreenSharingMediaTransport
  func mediaStatistics() -> [String: String]
  func closed() async -> String
  func close(_ reason: String)
}
