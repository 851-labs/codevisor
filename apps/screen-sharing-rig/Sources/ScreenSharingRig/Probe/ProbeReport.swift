import ScreenSharingDiagnostics
#if os(macOS)
  import AppKit
  import ScreenSharing
  import Foundation
  import QuartzCore
  import ScreenCaptureKit
  @preconcurrency import WebRTC

  struct ProbeReport: Encodable {
    let mode: ProbeOptions.Mode
    let configuration: ScreenSharingVideoConfiguration
    let source: String
    let startedAtSeconds: Double
    let elapsedSeconds: Double
    let passed: Bool
    let renderingEnabled: Bool
    let sender: ScreenSharingMetrics.Snapshot
    let receiver: ScreenSharingMetrics.Snapshot
    let senderRTC: [String: String]
    let receiverRTC: [String: String]
    let rendererMailboxDrops: Int
    let presentedFramesPerSecond: Double
    let timeline: [ProbeTimeline.Sample]
    let transportTimeline: [ProbeTransportTimeline.Sample]
    let receiverDeliveryAudit: ScreenSharingFrameDeliveryAudit.Snapshot?
    let receiverRtcEventLog: ScreenSharingRtcEventLogDiagnostic.Record?
    let senderRtcEventLog: ScreenSharingRtcEventLogDiagnostic.Record?
  }
#endif
