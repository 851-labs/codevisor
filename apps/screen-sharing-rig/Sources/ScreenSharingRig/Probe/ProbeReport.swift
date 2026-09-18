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
    /// Receiver-only diagnostic audit snapshot taken at report time (before close); absent when not requested.
    let receiverDeliveryAudit: ScreenSharingFrameDeliveryAudit.Snapshot?
    /// Receiver-only diagnostic RTC event-log lifecycle record (final at report time); absent when not requested.
    let receiverRtcEventLog: ScreenSharingRtcEventLogDiagnostic.Record?
    /// Sender-only diagnostic RTC event-log lifecycle record on the sending peer; absent when not requested.
    let senderRtcEventLog: ScreenSharingRtcEventLogDiagnostic.Record?
  }
#endif
