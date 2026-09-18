import ScreenSharing
import ScreenSharingWebRTC
import ScreenSharingDiagnostics
import CoreVideo
import Foundation

struct ProbeOptions {
  enum Mode: String, Codable { case loopback, send, receive }
  typealias SyntheticPixelFormat = ScreenSharingDiagnostics.SyntheticPixelFormat
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

}
