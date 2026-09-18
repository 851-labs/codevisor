/// Where a capture source delivers frames. The WebRTC sender is the product's
/// sink; the engine's capture and the rig's synthetic sources only ever push,
/// so they never see the transport behind it.
public protocol ScreenSharingFrameSink: Sendable {
  func push(_ frame: ScreenSharingVideoFrame)
}
