import ScreenSharing
import ScreenSharingDiagnostics
import CoreVideo
import Foundation

extension ProbeOptions {
  init(arguments: [String]) throws {
    let parsed = try ProbeArguments(arguments)
    let values = parsed.values
    let flags = parsed.flags
    guard flags.intersection(["--loopback", "--send", "--receive"]).count <= 1 else {
      throw ScreenSharingError.invalid("Choose one probe mode.")
    }
    mode = flags.contains("--send") ? .send : flags.contains("--receive") ? .receive : .loopback
    func integer(_ key: String, fallback: Int) throws -> Int {
      guard let value = values[key] else { return fallback }
      guard let parsed = Int(value) else { throw ScreenSharingError.invalid("Invalid \(key).") }
      return parsed
    }
    configuration = try ScreenSharingVideoConfiguration(
      width: integer("--width", fallback: 1920), height: integer("--height", fallback: 1080),
      framesPerSecond: integer("--fps", fallback: 60), bitrate: integer("--bitrate", fallback: 12_000_000))
    guard let duration = Double(values["--duration"] ?? "10"), duration.isFinite, (1...3600).contains(duration) else {
      throw ScreenSharingError.invalid("Duration must be 1...3600 seconds.")
    }
    self.duration = duration
    if let value = values["--display"] {
      guard let id = UInt32(value), mode != .receive else {
        throw ScreenSharingError.invalid("Invalid capture display.")
      }
      displayID = id
    } else {
      displayID = nil
    }
    offerURL = values["--offer"].map { URL(fileURLWithPath: $0).standardizedFileURL }
    answerURL = values["--answer"].map { URL(fileURLWithPath: $0).standardizedFileURL }
    reportURL = values["--report"].map { URL(fileURLWithPath: $0).standardizedFileURL }
    listDisplays = flags.contains("--list-displays")
    capabilities = flags.contains("--capabilities")
    checkQuality = flags.contains("--check-quality")
    checkRecovery = flags.contains("--check-recovery")
    headlessRecovery = flags.contains("--headless-recovery")
    headless = headlessRecovery || flags.contains("--headless")
    dropRecoveryKeyframe = flags.contains("--drop-recovery-keyframe")
    idleOnDecoderReset = flags.contains("--idle-on-decoder-reset")
    if let raw = values["--pause-source-after"] {
      guard headless, mode != .receive, let seconds = Double(raw), seconds.isFinite, seconds >= 3,
        seconds + 3 <= duration
      else {
        throw ScreenSharingError.invalid(
          "Source pause requires a headless sender, at least 3 active seconds and 3 remaining seconds.")
      }
      pauseSourceAfterSeconds = seconds
    } else {
      pauseSourceAfterSeconds = nil
    }
    if idleOnDecoderReset, !headlessRecovery || pauseSourceAfterSeconds != nil {
      throw ScreenSharingError.invalid("Idle-at-reset requires headless recovery and excludes timed source pause.")
    }
    finalBurstSignal = flags.contains("--final-burst-signal")
    if finalBurstSignal, pauseSourceAfterSeconds == nil || values["--report"] == nil {
      throw ScreenSharingError.invalid("The final-burst signal requires --pause-source-after and --report.")
    }
    captureOwnedWindow = flags.contains("--capture-owned-window")
    if captureOwnedWindow {
      let excluded: Set<String> = [
        "--display", "--capture-picker", "--capture-picker-window", "--pause-source-after", "--final-burst-signal",
        "--show-workload", "--workload-window", "--record-workload-times", "--check-quality", "--check-recovery",
        "--headless-recovery", "--idle-on-decoder-reset", "--drop-recovery-keyframe", "--synthetic-gap-ms",
        "--desktop-pattern", "--synthetic-format", "--list-displays", "--capabilities", "--check-codecs",
        "--request-screen-recording", "--check-host", "--observe-window", "--keep-front", "--viewer-display",
        "--render-fps", "--render-on-arrival", "--metal-display-link", "--render-off-main",
        "--rtc-event-log-begin", "--rtc-event-log-duration",
      ]
      let present = excluded.intersection(flags).union(excluded.intersection(values.keys)).sorted()
      guard flags.contains("--headless"), mode != .receive, present.isEmpty else {
        throw ScreenSharingError.invalid(
          "Owned-window capture requires --headless with --loopback or --send and excludes "
            + "display/picker/synthetic-pause/workload/quality/recovery/viewer options"
            + (present.isEmpty ? "." : " (given: \(present.joined(separator: " "))).")
        )
      }
    }
    recordOwnedWorkloadTimes = flags.contains("--record-owned-workload-times")
    if recordOwnedWorkloadTimes, !captureOwnedWindow || duration > 240 {
      throw ScreenSharingError.invalid(
        "Owned-workload draw timestamps require --capture-owned-window and a duration <=240.")
    }
    if let raw = values["--pause-workload-after"] {
      guard captureOwnedWindow, let seconds = Double(raw), seconds.isFinite, seconds >= 3, seconds + 3 <= duration
      else {
        throw ScreenSharingError.invalid(
          "Workload pause requires --capture-owned-window, at least 3 animated seconds and 3 remaining seconds.")
      }
      pauseWorkloadAfterSeconds = seconds
    } else {
      pauseWorkloadAfterSeconds = nil
    }
    let headlessMedia = headless
    func experimentMilliseconds(_ key: String) throws -> Int? {
      guard values[key] != nil else { return nil }
      let value = try integer(key, fallback: 0)
      guard (50...5000).contains(value), headlessMedia else {
        throw ScreenSharingError.invalid("\(key) requires a headless media probe and 50...5000 milliseconds.")
      }
      return value
    }
    idleThresholdMs = try experimentMilliseconds("--idle-threshold-ms")
    idleGraceMs = try experimentMilliseconds("--idle-grace-ms")
    syntheticGapMs = try experimentMilliseconds("--synthetic-gap-ms")
    if let idleThresholdMs, idleThresholdMs > 2000 {
      throw ScreenSharingError.invalid("--idle-threshold-ms must not exceed the 2000 ms slow re-offer interval.")
    }
    if values["--idle-grace-extensions"] != nil {
      let extensions = try integer("--idle-grace-extensions", fallback: 0)
      guard (0...10).contains(extensions), headlessMedia, mode != .send else {
        throw ScreenSharingError.invalid("--idle-grace-extensions requires a headless receiver and 0...10 windows.")
      }
      idleGraceExtensions = extensions
    } else {
      idleGraceExtensions = nil
    }
    sampleIntervalSeconds = try integer("--sample-interval-seconds", fallback: 30)
    guard (1...30).contains(sampleIntervalSeconds), Double(sampleIntervalSeconds) * 360 >= duration else {
      throw ScreenSharingError.invalid("--sample-interval-seconds must be 1...30 and allow at most 360 samples.")
    }
    traceBoundary = flags.contains("--trace-boundary")
    if traceBoundary, !headless {
      throw ScreenSharingError.invalid("Boundary tracing requires a headless media probe.")
    }
    if idleThresholdMs != nil, mode == .receive {
      throw ScreenSharingError.invalid("Idle threshold applies to a sender.")
    }
    if idleGraceMs != nil, mode == .send { throw ScreenSharingError.invalid("Delivery grace applies to a receiver.") }
    if syntheticGapMs != nil, mode == .receive { throw ScreenSharingError.invalid("Synthetic gaps apply to a sender.") }
    checkCodecs = flags.contains("--check-codecs")
    showWorkload = flags.contains("--show-workload")
    workloadWindow = flags.contains("--workload-window")
    recordWorkloadTimes = flags.contains("--record-workload-times")
    if recordWorkloadTimes, !showWorkload || duration > 240 {
      throw ScreenSharingError.invalid("Workload draw timestamps require --show-workload and a duration <=240.")
    }
    if workloadWindow, !showWorkload {
      throw ScreenSharingError.invalid("--workload-window requires --show-workload.")
    }
    requestScreenRecording = flags.contains("--request-screen-recording")
    userInitiatedActivity = flags.contains("--user-initiated-activity")
    if userInitiatedActivity,
      listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("A user-initiated activity requires a media probe.")
    }
    keepFront = flags.contains("--keep-front")
    renderOnArrival = flags.contains("--render-on-arrival")
    metalDisplayLink = flags.contains("--metal-display-link")
    if metalDisplayLink,
      renderOnArrival || mode == .send || listDisplays || capabilities || checkCodecs || showWorkload
        || requestScreenRecording || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid(
        "Metal display link requires a viewer or loopback without arrival-driven rendering.")
    }
    if values["--render-fps"] != nil {
      let requested = try integer("--render-fps", fallback: 60)
      guard (30...240).contains(requested), !renderOnArrival, mode != .send,
        !listDisplays, !capabilities, !checkCodecs, !showWorkload, !requestScreenRecording,
        values["--check-host"] == nil
      else {
        throw ScreenSharingError.invalid(
          "Render FPS requires a display-link viewer or loopback and a cadence from 30 through 240.")
      }
      renderFPS = requested
    } else {
      renderFPS = nil
    }
    if let value = values["--viewer-display"] {
      guard let id = UInt32(value), id > 0, mode != .send,
        !listDisplays, !capabilities, !checkCodecs, !showWorkload, !requestScreenRecording,
        values["--check-host"] == nil
      else {
        throw ScreenSharingError.invalid("Viewer display requires a viewer or loopback and a positive display ID.")
      }
      viewerDisplayID = id
    } else {
      viewerDisplayID = nil
    }
    drawableCount = try integer("--drawable-count", fallback: 3)
    unsyncedPresentation = flags.contains("--unsynced-presentation")
    if values["--drawable-count"] != nil || unsyncedPresentation {
      guard (2...3).contains(drawableCount), mode != .send, !listDisplays, !capabilities, !checkCodecs,
        !showWorkload, !requestScreenRecording, values["--check-host"] == nil
      else {
        throw ScreenSharingError.invalid(
          "Presentation experiments require a viewer or loopback, with two or three drawables.")
      }
    }
    renderOffMain = flags.contains("--render-off-main")
    if renderOffMain,
      !renderOnArrival || metalDisplayLink || unsyncedPresentation || mode == .send || listDisplays || capabilities
        || checkCodecs || showWorkload || requestScreenRecording || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid(
        "Off-main render preparation requires a viewer or loopback with --render-on-arrival and synchronized presentation; "
          + "it excludes --metal-display-link and --unsynced-presentation.")
    }
    standardRateControl = flags.contains("--standard-rate-control")
    prioritizeSpeed = flags.contains("--prioritize-encoding-speed")
    if prioritizeSpeed, !standardRateControl {
      throw ScreenSharingError.invalid("Encoding speed experiments require standard rate control.")
    }
    maintainSourceRate = flags.contains("--fixed-source-rate")
    staticCodecRate = flags.contains("--static-codec-rate")
    completeEachFrame = flags.contains("--complete-each-frame")
    if completeEachFrame,
      mode == .receive || listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("Per-frame completion requires sending media.")
    }
    if staticCodecRate,
      mode == .receive || listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("A static codec rate requires sending media.")
    }
    if maintainSourceRate,
      mode == .receive || listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("A fixed source rate requires sending media.")
    }
    encoderInFlight = try integer("--encoder-inflight", fallback: 2)
    keyframeIntervalSeconds = try integer("--keyframe-interval", fallback: 2)
    if values["--keyframe-interval"] != nil {
      guard (1...60).contains(keyframeIntervalSeconds), mode != .receive, !listDisplays, !capabilities,
        !checkCodecs, !showWorkload, !requestScreenRecording, values["--check-host"] == nil
      else { throw ScreenSharingError.invalid("Keyframe interval requires sending media and 1...60 seconds.") }
    }
    if values["--encoder-inflight"] != nil {
      guard (1...8).contains(encoderInFlight), mode != .receive, !listDisplays, !capabilities,
        !checkCodecs, !showWorkload, !requestScreenRecording, values["--check-host"] == nil
      else { throw ScreenSharingError.invalid("Encoder admission requires sending media and 1...8 frames.") }
    }
    disableLookAhead = flags.contains("--no-lookahead")
    if disableLookAhead, !standardRateControl {
      throw ScreenSharingError.invalid("--no-lookahead requires --standard-rate-control.")
    }
    capturePickerWindow = flags.contains("--capture-picker-window")
    if capturePickerWindow, flags.contains("--capture-picker") {
      throw ScreenSharingError.invalid("Choose one capture picker mode.")
    }
    capturePicker = flags.contains("--capture-picker") || capturePickerWindow
    desktopPattern = flags.contains("--desktop-pattern")
    if desktopPattern,
      mode == .receive || displayID != nil || capturePicker || listDisplays || capabilities || checkCodecs
        || showWorkload || requestScreenRecording || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("The desktop pattern requires a synthetic sender or loopback.")
    }
    copyCaptureSurface = flags.contains("--copy-capture-surface")
    if copyCaptureSurface,
      (!capturePicker && displayID == nil) || listDisplays || capabilities || checkCodecs || showWorkload
        || requestScreenRecording || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("Copying capture surfaces requires desktop capture.")
    }
    captureQueueDepth = try integer("--capture-queue-depth", fallback: 3)
    if values["--capture-queue-depth"] != nil,
      !(3...8).contains(captureQueueDepth) || (!capturePicker && displayID == nil)
        || listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("Capture queue depth requires desktop capture and 3...8 surfaces.")
    }
    if let raw = values["--capture-interval-fps"] {
      guard let requested = Int(raw), requested >= configuration.framesPerSecond,
        requested <= ScreenSharingCaptureIntervalRequest.maximumFramesPerSecond
      else {
        throw ScreenSharingError.invalid(
          "Capture interval request must be an integer from the video rate up to 120 fps.")
      }
      guard captureOwnedWindow || capturePicker || displayID != nil, mode != .receive,
        !listDisplays, !capabilities, !checkCodecs, !showWorkload, !requestScreenRecording,
        values["--check-host"] == nil, !flags.contains("--observe-window"), !flags.contains("--clock-sync")
      else {
        throw ScreenSharingError.invalid(
          "Capture interval request requires real ScreenCaptureKit capture (display, picker or owned window).")
      }
      captureIntervalFPS = requested
    } else {
      captureIntervalFPS = nil
    }
    if capturePicker,
      mode == .receive || displayID != nil || listDisplays || capabilities || checkCodecs || showWorkload
        || requestScreenRecording || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("The capture picker requires a sender or loopback, without --display.")
    }
    if values["--jitter-window-frames"] != nil {
      let window = try integer("--jitter-window-frames", fallback: 60)
      guard (30...600).contains(window), mode != .send, !listDisplays, !capabilities, !checkCodecs,
        !showWorkload, !requestScreenRecording, values["--check-host"] == nil
      else {
        throw ScreenSharingError.invalid("Jitter window requires receiving media or loopback and 30...600 frames.")
      }
      jitterWindowFrames = window
    } else {
      jitterWindowFrames = nil
    }
    lowLatencyPlayout = flags.contains("--low-latency-playout")
    if lowLatencyPlayout,
      mode == .send || listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("Low-latency playout requires receiving media or loopback.")
    }
    let minRaw = values["--playout-delay-min-ms"], maxRaw = values["--playout-delay-max-ms"]
    if minRaw != nil || maxRaw != nil {
      guard let minRaw, let maxRaw, let minMs = Int(minRaw), let maxMs = Int(maxRaw), 0 <= minMs, minMs <= maxMs,
        maxMs <= 500
      else {
        throw ScreenSharingError.invalid(
          "Playout delay bounds need both --playout-delay-min-ms and --playout-delay-max-ms with 0 <= min <= max <= 500."
        )
      }
      guard !lowLatencyPlayout,
        mode != .send, !listDisplays, !capabilities, !checkCodecs, !showWorkload, !requestScreenRecording,
        values["--check-host"] == nil, !flags.contains("--observe-window"), !flags.contains("--clock-sync")
      else {
        throw ScreenSharingError.invalid(
          "Playout delay bounds require receiving media or loopback and exclude --low-latency-playout.")
      }
      playoutDelayBoundsMs = (min: minMs, max: maxMs)
    } else {
      playoutDelayBoundsMs = nil
    }
    let diagnostics = try ProbeDiagnostics(
      arguments: parsed, mode: mode, duration: duration, headless: headless,
      captureOwnedWindow: captureOwnedWindow, reportURL: reportURL)
    deliveryAuditWindow = diagnostics.deliveryAuditWindow
    rtcEventLogWindow = diagnostics.rtcEventLogWindow
    rtcEventLogPath = diagnostics.rtcEventLogPath
    senderRtcEventLogWindow = diagnostics.senderRtcEventLogWindow
    senderRtcEventLogPath = diagnostics.senderRtcEventLogPath
    guard let pixelFormat = SyntheticPixelFormat(rawValue: values["--synthetic-format"] ?? "bgra") else {
      throw ScreenSharingError.invalid("Synthetic format must be bgra or nv12.")
    }
    syntheticPixelFormat = pixelFormat
    guard let videoCodec = ScreenSharingVideoCodec(rawValue: values["--codec"] ?? "h264") else {
      throw ScreenSharingError.invalid("Codec must be h264, hevc or hevc444.")
    }
    self.videoCodec = videoCodec
    if let captureFormat = values["--capture-format"] {
      guard ["nv12", "bgra"].contains(captureFormat), displayID != nil || capturePicker,
        !listDisplays, !capabilities, !checkCodecs, !showWorkload, !requestScreenRecording,
        values["--check-host"] == nil, videoCodec != .hevc444 || captureFormat == "bgra"
      else { throw ScreenSharingError.invalid("Capture format requires desktop capture; HEVC 4:4:4 requires BGRA.") }
      capturePixelFormat =
        captureFormat == "bgra" ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    } else {
      capturePixelFormat = videoCodec.capturePixelFormat
    }
    if values["--codec"] != nil,
      listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("--codec requires a media probe.")
    }
    if videoCodec == .hevc444, mode != .receive,
      !standardRateControl || syntheticPixelFormat == .nv12
    {
      throw ScreenSharingError.invalid("HEVC 4:4:4 requires standard rate control and full-chroma source input.")
    }
    if values["--synthetic-format"] != nil,
      mode == .receive || displayID != nil || capturePicker || listDisplays || capabilities || checkCodecs
        || showWorkload
        || requestScreenRecording || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("Synthetic format requires a synthetic sender or loopback.")
    }
    if standardRateControl,
      mode == .receive || listDisplays || capabilities || checkCodecs || showWorkload || requestScreenRecording
        || values["--check-host"] != nil
    {
      throw ScreenSharingError.invalid("Standard rate control requires sending media or loopback.")
    }
    codecCase = values["--codec-case"]
    if codecCase != nil, !checkCodecs { throw ScreenSharingError.invalid("--codec-case requires --check-codecs.") }
    if checkCodecs, mode != .loopback || checkQuality || displayID != nil {
      throw ScreenSharingError.invalid("Codec checks require local synthetic mode without quality transitions.")
    }
    if let value = values["--check-host"] {
      guard let url = URL(string: value), url.user == nil, url.password == nil,
        url.scheme == "https"
          || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(url.host ?? "")),
        let workspace = UUID(uuidString: values["--workspace"] ?? ""),
        let pane = UUID(uuidString: values["--pane"] ?? ""), mode == .loopback, !checkQuality
      else { throw ScreenSharingError.invalid("Host checks require HTTPS (or loopback HTTP), a workspace and a pane.") }
      hostCheck = (url, workspace, pane)
    } else {
      guard values["--workspace"] == nil, values["--pane"] == nil else {
        throw ScreenSharingError.invalid("Workspace and pane require --check-host.")
      }
      hostCheck = nil
    }
    if checkQuality, mode != .loopback { throw ScreenSharingError.invalid("Quality checks require loopback mode.") }
    if dropRecoveryKeyframe, !checkRecovery {
      throw ScreenSharingError.invalid("Dropping recovery output requires --check-recovery.")
    }
    if headlessRecovery {
      guard checkRecovery, !keepFront, !renderOnArrival, renderFPS == nil, !metalDisplayLink,
        viewerDisplayID == nil, values["--drawable-count"] == nil, !unsyncedPresentation, !renderOffMain,
        !capturePicker, displayID == nil
      else {
        throw ScreenSharingError.invalid(
          "Headless recovery requires --check-recovery, synthetic input and no viewer options.")
      }
    }
    if headless {
      guard !keepFront, !renderOnArrival, renderFPS == nil, !metalDisplayLink,
        viewerDisplayID == nil, values["--drawable-count"] == nil, !unsyncedPresentation, !renderOffMain,
        !capturePicker, displayID == nil, !checkQuality, !checkCodecs, !showWorkload,
        !listDisplays, !capabilities, !requestScreenRecording, hostCheck == nil
      else {
        throw ScreenSharingError.invalid("Headless media requires synthetic input and no viewer or other checks.")
      }
    }
    if checkRecovery {
      guard mode == .loopback, !checkQuality, !checkCodecs, !showWorkload, !listDisplays, !capabilities,
        !requestScreenRecording, hostCheck == nil, keyframeIntervalSeconds >= 10, duration >= 10
      else {
        throw ScreenSharingError.invalid(
          "Recovery checks require media loopback, no other checks, a keyframe interval >=10 and duration >=10.")
      }
    }
    if mode != .loopback, offerURL == nil || answerURL == nil {
      throw ScreenSharingError.invalid("Send and receive require --offer and --answer paths.")
    }
    if showWorkload,
      mode != .loopback || displayID != nil || checkCodecs || checkQuality || capabilities || listDisplays
        || hostCheck != nil || offerURL != nil || answerURL != nil || renderOnArrival
    {
      throw ScreenSharingError.invalid("The desktop workload runs alone, without capture, peers or codec checks.")
    }
    if requestScreenRecording,
      mode != .loopback || showWorkload || displayID != nil || checkCodecs || checkQuality || capabilities
        || listDisplays || hostCheck != nil || offerURL != nil || answerURL != nil || reportURL != nil
    {
      throw ScreenSharingError.invalid("Request Screen Recording permission separately from other probe operations.")
    }
    let paths = [offerURL, answerURL, reportURL].compactMap { $0?.path }
    guard Set(paths).count == paths.count else { throw ScreenSharingError.invalid("Output paths must be distinct.") }
  }
}
