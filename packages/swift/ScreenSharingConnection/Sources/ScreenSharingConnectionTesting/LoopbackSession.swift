import Foundation
import Observation
import ScreenSharing
import ScreenSharingTesting
import ScreenSharingV2

@MainActor
@Observable
public final class LoopbackSession: ScreenSharingV2StartableSession {
  public let host: ScreenSharingLocalViewingHost
  public var presentsTiles = false
  public private(set) var tokens: [String] = []
  @ObservationIgnored private let viewing: ScreenSharingLocalViewingSession

  @ObservationIgnored private let hangsInHandshake: Bool
  @ObservationIgnored private var handshake: CheckedContinuation<Void, any Error>?

  public init(hangsInHandshake: Bool = false) {
    self.hangsInHandshake = hangsInHandshake
    (viewing, host) = ScreenSharingLocalViewingSession.connected()
  }

  public var capabilities: ScreenSharingCapabilities { viewing.capabilities }
  public var frames: ScreenSharingFrameMailbox { viewing.frames }
  public var metrics: ScreenSharingMetrics { viewing.metrics }
  public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { viewing.control }
  public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { viewing.clipboard }
  public var failure: String? { viewing.failure }
  public var isClosed: Bool { viewing.isClosed }

  public var onConnectionChanged: ((String) -> Void)? {
    get { viewing.onConnectionChanged }
    set { viewing.onConnectionChanged = newValue }
  }

  public func start(token: String) async throws {
    tokens.append(token)
    guard hangsInHandshake else { return }

    try await withCheckedThrowingContinuation { handshake = $0 }
  }

  public func statistics() async -> [String: String] { await viewing.statistics() }

  public func close() {
    viewing.close()
    handshake?.resume(throwing: ScreenSharingError.unavailable("The connection closed in this test."))
    handshake = nil
  }
}
