import ScreenSharing

@MainActor
public protocol ScreenSharingOfferingSession: ScreenSharingViewingSession {
  func offer() async throws -> String
  func accept(_ answer: String) async throws
}

extension ScreenSharingReceiver: ScreenSharingOfferingSession {
  public func offer() async throws -> String { try await makeDescription(offer: true).sdp }
  public func accept(_ answer: String) async throws { try await accept(.init(kind: "answer", sdp: answer)) }
}
