import CodevisorScreenSharing
import CoreVideo
import Foundation

struct ProbeOptions {
  enum Mode: String, Codable { case loopback, send, receive }
  enum SyntheticPixelFormat: String { case bgra, nv12 }
  let mode: Mode
  let configuration: ScreenSharingVideoConfiguration
  let duration: Double
  let displayID: UInt32?
  let capturePicker: Bool
  let capturePickerWindow: Bool
  let captureQueueDepth: Int
  /// Optional SCK minimum-frame-interval request (fps), isolated from the video rate; nil = existing behaviour.
  let captureIntervalFPS: Int?
  let copyCaptureSurface: Bool
  let capturePixelFormat: OSType
  let offerURL: URL?
  let answerURL: URL?
  let reportURL: URL?
  let listDisplays: Bool
  let capabilities: Bool
  let checkQuality: Bool
  let checkRecovery: Bool
  let headlessRecovery: Bool
  let headless: Bool
  let dropRecoveryKeyframe: Bool
  let pauseSourceAfterSeconds: Double?
  let finalBurstSignal: Bool
  let captureOwnedWindow: Bool
  let recordOwnedWorkloadTimes: Bool
  let pauseWorkloadAfterSeconds: Double?
  let idleThresholdMs: Int?
  let idleGraceMs: Int?
  let idleGraceExtensions: Int?
  let traceBoundary: Bool
  let sampleIntervalSeconds: Int
  let syntheticGapMs: Int?
  let idleOnDecoderReset: Bool
  let checkCodecs: Bool
  let showWorkload: Bool
  let workloadWindow: Bool
  let recordWorkloadTimes: Bool
  let requestScreenRecording: Bool
  let keepFront: Bool
  let renderOnArrival: Bool
  let renderFPS: Int?
  let metalDisplayLink: Bool
  let viewerDisplayID: UInt32?
  let drawableCount: Int
  let unsyncedPresentation: Bool
  /// Diagnostic: drawable acquisition and encoding on a serial worker (viewer/loopback, arrival-driven, synchronized).
  let renderOffMain: Bool
  let standardRateControl: Bool
  let disableLookAhead: Bool
  let encoderInFlight: Int
  let maintainSourceRate: Bool
  let staticCodecRate: Bool
  let completeEachFrame: Bool
  let prioritizeSpeed: Bool
  let desktopPattern: Bool
  let userInitiatedActivity: Bool
  let keyframeIntervalSeconds: Int
  let syntheticPixelFormat: SyntheticPixelFormat
  let videoCodec: ScreenSharingVideoCodec
  /// The process-wide trial selection these options require, derived by the shared library factory that the boundary
  /// and its tests use, so this file cannot drift from what is actually installed.
  var fieldTrialSelection: ScreenSharingFieldTrials.Selection {
    .probeOptions(
      jitterWindowFrames: jitterWindowFrames, lowLatencyPlayout: lowLatencyPlayout,
      playoutDelayBoundsMs: playoutDelayBoundsMs)
  }

  let jitterWindowFrames: Int?
  let lowLatencyPlayout: Bool
  /// Receiver-only diagnostic: explicit WebRTC-ForcePlayoutDelay bounds (min_ms, max_ms) in milliseconds.
  let playoutDelayBoundsMs: (min: Int, max: Int)?
  /// Receiver-only diagnostic frame-delivery audit window (seconds relative to the receiver's media start).
  let deliveryAuditWindow: (beginSeconds: Double, durationSeconds: Double)?
  /// Receiver-only diagnostic: WebRTC RTC event log window (seconds relative to media start) and its raw output path
  /// derived from the report stem; nil = no log object, nothing scheduled.
  let rtcEventLogWindow: (beginSeconds: Double, durationSeconds: Double)?
  let rtcEventLogPath: String?
  /// Sender-only diagnostic: the same WebRTC RTC event log on the SENDING peer (send or loopback; owned-window source and
  /// plain headless sender included); raw path REPORT.sender-rtc-event-log.binarypb; nil = no log object, nothing scheduled.
  let senderRtcEventLogWindow: (beginSeconds: Double, durationSeconds: Double)?
  let senderRtcEventLogPath: String?
  let codecCase: String?
  let hostCheck: (url: URL, workspace: UUID, pane: UUID)?

  static let usage = """
    screen-sharing-probe [--loopback | --send | --receive] [options]
      --width 1920 --height 1080 --fps 60 --bitrate 12000000
      --duration 10          Measured seconds after connection (1...3600)
      --report /path.json    Write metrics; no SDP, addresses or credentials
      --display ID          Capture this Mac display instead of synthetic motion
      --capture-picker      Select a display through macOS's system sharing picker
      --capture-picker-window
                            Select a single window through the system sharing picker
      --capture-interval-fps N
                            Request a ScreenCaptureKit minimum frame interval of 1/N s independent of
                            --fps (N from the video rate up to 120); real SCK capture only
                            (display, picker or owned window); request telemetry, not a frame promise
      --capture-queue-depth N
                            SCK surface pool experiment, 3...8 (default 3)
      --capture-format nv12|bgra
                            Compare SCK output formats (default nv12; hevc444 uses bgra)
      --copy-capture-surface
                            Transfer SCK frames into a separate pool of at most six buffers
      --capabilities        Report local VT codec advertisements (not a HEVC benchmark)
      --check-quality       Exercise live capture format changes in loopback
      --check-recovery      Reset decoder state after 120 frames; require recovery within 2 seconds
                            Loopback only; --keyframe-interval >=10 and --duration >=10
      --headless-recovery   Run --check-recovery without a window; verifies decoding, not presentation
      --headless            Synthetic send/receive/loopback without a window; decoding telemetry only
      --drop-recovery-keyframe
                            Discard one forced encoder output after reset; requires --check-recovery
      --pause-source-after N
                            Headless recovery diagnostic: stop synthetic input, then observe idle output
      --capture-owned-window
                            Headless loopback/send diagnostic: capture this process's own workload
                            window through ScreenCaptureKit (current-process content, exact window
                            and owning process; no display or other-window fallback), no viewer
                            rendering; excludes display/picker/synthetic-pause/workload/quality/
                            recovery options
      --pause-workload-after N
                            With --capture-owned-window: stop the workload animation after N
                            seconds (>=3, leaving >=3); the static window stays captured
      --record-owned-workload-times
                            With --capture-owned-window and a duration <=240: retain the first
                            AppKit draw-call start per marker code (at most 20000) in
                            REPORT.workload-times.json; the same schema as --record-workload-times.
                            Nothing is retained without this flag.
      --final-burst-signal  With --pause-source-after and --report: publish REPORT.final-burst.json,
                            keep capturing 250 ms, then stop; a loss relay drops that final content
      --idle-threshold-ms N Host idle-notice threshold, 50...2000 (product default 100; the slow
                            re-offer phase never runs faster than the threshold; 500 = former default)
      --idle-grace-ms N     Viewer delivery grace before a refresh, 50...5000 (product default 100;
                            500 = former default)
      --idle-grace-extensions N
                            Extend the grace up to N more windows while newer content keeps
                            arriving, 0...10 (product default 4; 0 = former fixed grace)
      --trace-boundary      Headless diagnostic: record bounded refresh/encoder/decoder boundary
                            traces and WebRTC drop messages in the report
      --sample-interval-seconds N
                            Resource/cadence timeline sample interval, 1...30 (default 30);
                            the run may retain at most 360 samples
      --synthetic-gap-ms N  Bursty synthetic input: 250 ms bursts separated by N ms gaps, 50...5000
      --idle-on-decoder-reset
                            Stop capture delivery at reset to check recovery from an idle source
      --check-codecs        Hardware VT round trips, actual HEVC chroma, text images;
                            optional --report also creates a sibling .images directory
      --show-workload       Show a timed fullscreen text/motion/input target, without capture;
                            --width/--height set its raster, --duration bounds its lifetime
      --workload-window     Give that target its exact backing-pixel size, even beyond display bounds
      --record-workload-times
                            Retain the first draw timestamp for each code; workload only, duration <=240
      --clock-sync         Run alone: reply to integer stdin requests with local monotonic timestamps
      --observe-window     Separate diagnostic: choose a viewer window and record frame codes/timestamps
                            Accepts --content-top-points N, --width, --height, --duration (1...120),
                            and a required --report path; source raster defaults to 3840x2160.
                            Optional --window-id ID uses existing capture permission instead of the picker.
      --request-screen-recording
                            Ask macOS for this diagnostic app's capture permission, then exit
      --keep-front          Keep the diagnostic viewer above other windows during measurement
      --render-on-arrival   Compare bounded frame-triggered rendering with the display-link baseline
      --render-fps N        Request a display-link cadence, 30...240; excludes --render-on-arrival
      --metal-display-link  Use CAMetalDisplayLink supplied drawables; excludes --render-on-arrival
      --viewer-display ID   Place the diagnostic viewer on this currently attached local display
      --drawable-count 2|3  Compare Metal drawable-pool bounds (default 3)
      --render-off-main     Diagnostic: acquire drawables and encode on a serial worker; requires
                            --render-on-arrival; excludes --metal-display-link and --unsynced-presentation
      --unsynced-presentation
                            macOS experiment: disable Metal display synchronization
      --standard-rate-control
                            Experiment with standard VT rate control; same two-frame admission bound
      --no-lookahead        Request zero encoder lookahead with standard rate control (macOS)
      --encoder-inflight N  Encoder admission experiment, 1...8 (default 2)
      --keyframe-interval N Periodic keyframe interval in nominal seconds, 1...60 (default 2)
      --fixed-source-rate   Disable WebRTC format adaptation; retain bitrate control and bounded frame admission
      --static-codec-rate   Isolate encoder reconfiguration by retaining its initial bitrate and FPS
      --complete-each-frame Request synchronous completion through each submitted frame's timestamp
      --prioritize-encoding-speed
                            Use the speed preference advertised by the standard encoder's High Speed preset
      --desktop-pattern     Use the desktop benchmark drawing as synthetic input, without SCK
      --user-initiated-activity
                            Hold a user-initiated process activity during media; allow idle system sleep
      --synthetic-format bgra|nv12
                            Synthetic sender input (default bgra); nv12 converts before WebRTC
      --codec h264|hevc|hevc444
                            Native transport experiment (default h264); hevc444 sender requires
                            --standard-rate-control and preserves full chroma from BGRA capture
      --jitter-window-frames N
                            Receiver experiment: estimate max frame size using p95 over N frames (30...600)
      --low-latency-playout  Receiver experiment: request zero-delay WebRTC playout; may increase stuttering
      --playout-delay-min-ms N --playout-delay-max-ms N
                            Receiver experiment: force WebRTC playout delay bounds (both required,
                            0 <= min <= max <= 500 ms; a positive minimum avoids ASAP rendering);
                            an experiment, not a latency guarantee; excludes --low-latency-playout
      --rtc-event-log-begin S --rtc-event-log-duration S
                            Receiver-only diagnostic: start WebRTC's RTC event log (shipped API, 8 MiB cap) at
                            S seconds after media start and stop it duration seconds later, both from the
                            measurement ticks with CACurrentMediaTime read before and after each call; the raw
                            log is REPORT.rtc-event-log.binarypb (an existing entry is refused at option time
                            and again by an exclusive reservation just before the start); the lifecycle record
                            is REPORT.rtc-event-log.json on every exit path; --receive or --loopback with
                            --report, duration 1...120, window inside --duration; the file also holds WebRTC's
                            bounded pre-start history and is judged offline, not here
      --sender-rtc-event-log-begin S --sender-rtc-event-log-duration S
                            Sender-only diagnostic: the same RTC event log on the SENDING peer (--send or --loopback,
                            owned-window source and headless sender included; may coexist with the receiver log in
                            loopback); raw REPORT.sender-rtc-event-log.binarypb, record REPORT.sender-rtc-event-log.json;
                            outgoing packet events are stamped at the post-pacer transport hand-off, not NIC egress
      --delivery-audit-begin S --delivery-audit-duration S
                            Receiver-only diagnostic: record scalar frame-delivery boundaries (decoder input …
                            presented result) for S..S+duration seconds after media start; viewer or loopback,
                            not headless/sender/owned capture/observer; duration 1...120, window within --duration
      --codec-case NAME     Run only this --check-codecs case, e.g. hevc-nv24
      --check-host URL --workspace UUID --pane UUID
                            Verify authenticated native-host recovery using an existing pane;
                            optional token comes from CODEVISOR_SCREEN_SHARING_PROBE_TOKEN
      --list-displays       List displays (requires Screen Recording permission)
      --offer /path.json --answer /path.json
                            Required for send/receive; exchange using a trusted channel
    Sender writes offer and waits up to 120 seconds for answer file.
    Receiver reads offer, writes answer, then waits for sender to connect.
    Loopback creates two real WebRTC peers on this Mac. It is not a LAN benchmark.
    """

  init(arguments: [String]) throws {
    var values: [String: String] = [:]
    var flags = Set<String>()
    let switches = [
      "--loopback", "--send", "--receive", "--list-displays", "--capabilities", "--check-quality", "--check-codecs",
      "--keep-front", "--render-on-arrival", "--standard-rate-control", "--capture-picker", "--unsynced-presentation",
      "--render-off-main",
      "--show-workload", "--no-lookahead", "--fixed-source-rate", "--copy-capture-surface", "--static-codec-rate",
      "--complete-each-frame", "--check-recovery", "--headless-recovery", "--drop-recovery-keyframe",
      "--idle-on-decoder-reset", "--headless", "--final-burst-signal", "--trace-boundary", "--capture-owned-window",
      "--record-owned-workload-times",
      "--prioritize-encoding-speed", "--desktop-pattern", "--user-initiated-activity",
      "--request-screen-recording", "--capture-picker-window", "--workload-window",
      "--record-workload-times",
      "--low-latency-playout",
      "--metal-display-link",
    ]
    let valued = [
      "--width", "--height", "--fps", "--bitrate", "--duration", "--display", "--offer", "--answer", "--report",
      "--check-host", "--workspace", "--pane", "--codec-case", "--synthetic-format", "--jitter-window-frames",
      "--playout-delay-min-ms", "--playout-delay-max-ms", "--delivery-audit-begin", "--delivery-audit-duration",
      "--rtc-event-log-begin", "--rtc-event-log-duration",
      "--sender-rtc-event-log-begin", "--sender-rtc-event-log-duration",
      "--capture-queue-depth", "--capture-interval-fps",
      "--codec",
      "--drawable-count",
      "--render-fps",
      "--viewer-display",
      "--capture-format",
      "--encoder-inflight",
      "--keyframe-interval",
      "--pause-source-after",
      "--pause-workload-after",
      "--idle-threshold-ms",
      "--idle-grace-ms",
      "--idle-grace-extensions",
      "--synthetic-gap-ms",
      "--sample-interval-seconds",
    ]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard values[key] == nil, !flags.contains(key) else {
        throw ScreenSharingError.invalid("Repeated option: \(key)")
      }
      if switches.contains(key) {
        flags.insert(key)
      } else if valued.contains(key), index + 1 < arguments.count {
        index += 1
        values[key] = arguments[index]
      } else {
        throw ScreenSharingError.invalid("Unknown or incomplete option: \(key)\n\(Self.usage)")
      }
      index += 1
    }
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
