import ScreenSharingDiagnostics
import Foundation
import ScreenSharing

/// Validates bounded diagnostic windows and reserves no files during option parsing.
struct ProbeDiagnostics {
  let deliveryAuditWindow: (beginSeconds: Double, durationSeconds: Double)?
  let rtcEventLogWindow: (beginSeconds: Double, durationSeconds: Double)?
  let rtcEventLogPath: String?
  let senderRtcEventLogWindow: (beginSeconds: Double, durationSeconds: Double)?
  let senderRtcEventLogPath: String?

  init(
    arguments: ProbeArguments, mode: ProbeOptions.Mode, duration: Double, headless: Bool,
    captureOwnedWindow: Bool, reportURL: URL?
  ) throws {
    let values = arguments.values
    let flags = arguments.flags
    let listDisplays = flags.contains("--list-displays")
    let capabilities = flags.contains("--capabilities")
    let checkCodecs = flags.contains("--check-codecs")
    let showWorkload = flags.contains("--show-workload")
    let requestScreenRecording = flags.contains("--request-screen-recording")
    let auditBeginRaw = values["--delivery-audit-begin"], auditDurationRaw = values["--delivery-audit-duration"]
    if auditBeginRaw != nil || auditDurationRaw != nil {
      guard let auditBeginRaw, let auditDurationRaw, let begin = Double(auditBeginRaw),
        let auditDuration = Double(auditDurationRaw),
        begin.isFinite, auditDuration.isFinite, begin >= 0, (1...120).contains(auditDuration),
        begin + auditDuration <= Double(duration)
      else {
        throw ScreenSharingError.invalid(
          "The delivery audit needs both --delivery-audit-begin (>= 0) and --delivery-audit-duration (1...120) with the window inside --duration."
        )
      }
      guard mode != .send, !headless, !captureOwnedWindow, !listDisplays, !capabilities, !checkCodecs, !showWorkload,
        !requestScreenRecording, values["--check-host"] == nil, !flags.contains("--observe-window"),
        !flags.contains("--clock-sync"), flags.contains("--render-on-arrival"), !flags.contains("--metal-display-link")
      else {
        throw ScreenSharingError.invalid(
          "The delivery audit requires an arrival-driven rendering viewer or loopback (--render-on-arrival; no headless, sender, owned capture, observer, clock sync or --metal-display-link)."
        )
      }
      deliveryAuditWindow = (beginSeconds: begin, durationSeconds: auditDuration)
    } else {
      deliveryAuditWindow = nil
    }
    let logBeginRaw = values["--rtc-event-log-begin"], logDurationRaw = values["--rtc-event-log-duration"]
    if logBeginRaw != nil || logDurationRaw != nil {
      guard let logBeginRaw, let logDurationRaw, let begin = Double(logBeginRaw),
        let logDuration = Double(logDurationRaw), begin.isFinite, logDuration.isFinite, begin >= 0,
        (1...ScreenSharingRtcEventLogDiagnostic.Window.maximumDurationSeconds).contains(logDuration),
        begin + logDuration <= Double(duration)
      else {
        throw ScreenSharingError.invalid(
          "The RTC event log needs both --rtc-event-log-begin (>= 0) and --rtc-event-log-duration (1...120) with the window inside --duration."
        )
      }
      guard mode != .send, !captureOwnedWindow, !listDisplays, !capabilities, !checkCodecs, !showWorkload,
        !requestScreenRecording, values["--check-host"] == nil, !flags.contains("--observe-window"),
        !flags.contains("--clock-sync"), let reportURL
      else {
        throw ScreenSharingError.invalid(
          "The RTC event log requires a receiving media probe (--receive or --loopback) with --report; no sender, owned capture, observer, clock sync or host check."
        )
      }
      let path = reportURL.path + ".rtc-event-log.binarypb"
      try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(path)
      rtcEventLogWindow = (beginSeconds: begin, durationSeconds: logDuration)
      rtcEventLogPath = path
    } else {
      rtcEventLogWindow = nil
      rtcEventLogPath = nil
    }
    let sendLogBeginRaw = values["--sender-rtc-event-log-begin"]
    let sendLogDurationRaw = values["--sender-rtc-event-log-duration"]
    if sendLogBeginRaw != nil || sendLogDurationRaw != nil {
      guard let sendLogBeginRaw, let sendLogDurationRaw, let begin = Double(sendLogBeginRaw),
        let logDuration = Double(sendLogDurationRaw), begin.isFinite, logDuration.isFinite, begin >= 0,
        (1...ScreenSharingRtcEventLogDiagnostic.Window.maximumDurationSeconds).contains(logDuration),
        begin + logDuration <= Double(duration)
      else {
        throw ScreenSharingError.invalid(
          "The sender RTC event log needs both --sender-rtc-event-log-begin (>= 0) and --sender-rtc-event-log-duration (1...120) with the window inside --duration."
        )
      }
      guard mode != .receive, !listDisplays, !capabilities, !checkCodecs, !showWorkload, !requestScreenRecording,
        values["--check-host"] == nil, !flags.contains("--observe-window"), !flags.contains("--clock-sync"),
        let reportURL
      else {
        throw ScreenSharingError.invalid(
          "The sender RTC event log requires a sending media probe (--send or --loopback) with --report; no receiver-only, observer, clock sync or host check."
        )
      }
      let path = reportURL.path + ".sender-rtc-event-log.binarypb"
      try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(path)
      senderRtcEventLogWindow = (beginSeconds: begin, durationSeconds: logDuration)
      senderRtcEventLogPath = path
    } else {
      senderRtcEventLogWindow = nil
      senderRtcEventLogPath = nil
    }
  }
}
