import AppKit
import CodevisorClient
import ScreenSharing
import ScreenSharingV2
import CodevisorTestSupport
import CoreVideo
import Foundation
import Observation
import Synchronization
@testable import CodevisorCoreMac

@MainActor
@Observable
final class FakeChannel<Message: Sendable & Equatable>: ScreenSharingMessageChannel {
  var isAvailable = false {
    didSet { if isAvailable != oldValue { onAvailabilityChanged?(isAvailable) } }
  }
  @ObservationIgnored var onMessage: ((Message) -> Void)?
  @ObservationIgnored var onAvailabilityChanged: ((Bool) -> Void)?
  nonisolated let backgroundSent = Mutex<[Message]>([])
  nonisolated let sentInBackground = TestSignal()
  @ObservationIgnored var onSend: ((Message) -> Void)?
  private(set) var sent: [Message] = []
  private(set) var closed = false

  @discardableResult
  func send(_ message: Message) -> Bool {
    guard isAvailable else { return false }
    onSend?(message)
    sent.append(message)
    return true
  }
  func deliver(_ message: Message) { onMessage?(message) }
  func close() {
    closed = true
    isAvailable = false
    onMessage = nil
    onAvailabilityChanged = nil
  }
}

@MainActor
final class FakeMediaSession: ScreenSharingV2StartableSession {
  let capabilities: ScreenSharingCapabilities
  let frames = ScreenSharingFrameMailbox()
  let metrics = ScreenSharingMetrics()
  var presentsTiles = false
  let controlChannel = FakeChannel<ScreenSharingControlMessage>()
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? {
    capabilities.contains(.control) ? controlChannel : nil
  }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { nil }
  var failure: String?
  var onConnectionChanged: ((String) -> Void)?
  private(set) var desktopSizeRequests: [[Int]] = []
  func requestDesktopSize(width: Int, height: Int) { desktopSizeRequests.append([width, height]) }
  var resizesDesktop = false
  var initialDesktopSize: (width: Int, height: Int)? = (1024, 768)
  var linkBitsPerSecond: Double?
  var deliversVideo = true
  var supportsHighDynamicRange = false
  var supportsAudio = false
  private(set) var audioRequests: [Bool] = []
  func setAudioEnabled(_ enabled: Bool) { audioRequests.append(enabled) }
  private(set) var highDynamicRangeReports: [Bool] = []
  func setDisplayHighDynamicRange(_ supported: Bool) { highDynamicRangeReports.append(supported) }
  var onVideoFormatChanged: ((ScreenSharingDynamicRange, String?) -> Void)?
  var startHangs = false
  private var hungStart: CheckedContinuation<Void, any Error>?
  private(set) var tokens: [String] = []
  private(set) var closed = false

  init(capabilities: ScreenSharingCapabilities = [.control, .statistics]) { self.capabilities = capabilities }

  func start(token: String) async throws {
    tokens.append(token)
    if startHangs {
      try await withCheckedThrowingContinuation { hungStart = $0 }
    }
    controlChannel.isAvailable = true
    if deliversVideo { deliverFrame() }
  }
  func deliverFrame() {
    var pixel: CVPixelBuffer?
    CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel)
    if let pixel { frames.put(ScreenSharingVideoFrame(pixelBuffer: pixel, timestampNs: 0)) }
  }
  func statistics() async -> [String: String] { [:] }
  func close() {
    closed = true
    hungStart?.resume(throwing: RFBError.transport("The connection closed in this test."))
    hungStart = nil
    controlChannel.close()
    frames.clear()
  }
}

@MainActor
@Observable
final class FakeSurface: ScreenSharingViewerSurface {
  @ObservationIgnored let view: NSView
  @ObservationIgnored var onMovedToWindow: (() -> Void)?
  @ObservationIgnored var onFocusChanged: ((Bool) -> Void)?
  @ObservationIgnored var onInput: ((ScreenSharingInputEvent) -> Void)?
  @ObservationIgnored var onInputReleased: (() -> Void)?
  @ObservationIgnored var onKeyboardReturned: (() -> Void)?
  @ObservationIgnored var onSizeChanged: ((CGSize, CGFloat) -> Void)?
  @ObservationIgnored var onVideoSizeChanged: ((CGSize) -> Void)?
  @ObservationIgnored var onScreenHighDynamicRangeChanged: ((Bool) -> Void)?
  @ObservationIgnored var inputFailureMessage: String?
  @ObservationIgnored var capturesSystemShortcuts = true
  @ObservationIgnored var dropsInjectedInput = true
  @ObservationIgnored var beginInputSucceeds = true
  @ObservationIgnored var heldKey: UInt16?
  private(set) var inputActive = false
  private(set) var stopped = false
  private(set) var videoShowsPointer: Bool?

  init() {
    let focusable = FocusableView()
    view = focusable
    focusable.onMovedToWindow = { [weak self] in self?.onMovedToWindow?() }
  }

  func setVideoShowsPointer(_ shows: Bool) { videoShowsPointer = shows }

  func beginInput() -> Bool {
    guard beginInputSucceeds else { return false }
    inputActive = true
    return true
  }
  func releaseHeldInput() {
    guard let heldKey else { return }

    self.heldKey = nil
    onInput?(.key(code: heldKey, down: false, repeatKey: false, modifiers: 0))
  }
  func endInput() { inputActive = false }
  func stop() { stopped = true }
}

private final class FocusableView: NSView {
  var onMovedToWindow: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onMovedToWindow?()
  }
}

extension FakeChannel: ScreenSharingBackgroundSending {
  nonisolated func sendFromAnyThread(_ message: Message) -> Bool {
    backgroundSent.withLock { $0.append(message) }
    sentInBackground.signal()
    return true
  }
}
