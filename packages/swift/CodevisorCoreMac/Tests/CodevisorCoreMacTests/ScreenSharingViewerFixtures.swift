import AppKit
import CodevisorClient
import ScreenSharing
import CodevisorTestSupport
import Foundation
import Observation
@testable import CodevisorCoreMac

/// Shared fixtures of the viewer feature tests.
enum ScreenSharingViewerFixtures {
  static let display = ServerScreenSharingDisplay(id: "display", name: "Display", width: 1920, height: 1080)
  static let second = ServerScreenSharingDisplay(id: "second", name: "Second", width: 1280, height: 720)
}

/// A typed channel whose availability and inbound messages the test controls.
@MainActor
final class FakeChannel<Message: Sendable & Equatable>: ScreenSharingMessageChannel {
  var isAvailable = false {
    didSet { if isAvailable != oldValue { onAvailabilityChanged?(isAvailable) } }
  }
  var onMessage: ((Message) -> Void)?
  var onAvailabilityChanged: ((Bool) -> Void)?
  private(set) var sent: [Message] = []
  private(set) var closed = false

  @discardableResult
  func send(_ message: Message) -> Bool {
    guard isAvailable else { return false }
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

/// A media session without media: SDP is a fixture string, video readiness is
/// its surface presenting, and the control channel becomes available on accept.
@MainActor
final class FakeMediaSession: NativeScreenSharingMediaSession {
  let capabilities: ScreenSharingCapabilities
  let frames = ScreenSharingFrameMailbox()
  let metrics = ScreenSharingMetrics()
  let controlChannel = FakeChannel<ScreenSharingControlMessage>()
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? {
    capabilities.contains(.control) ? controlChannel : nil
  }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { nil }
  var failure: String?
  var onConnectionChanged: ((String) -> Void)?
  /// Every remote desktop size the endpoint asked for.
  private(set) var desktopSizeRequests: [[Int]] = []
  func requestDesktopSize(width: Int, height: Int) { desktopSizeRequests.append([width, height]) }
  /// A desktop that resizes (VNC-like), for Dynamic Resolution (851-2340).
  var resizesDesktop = false
  var initialDesktopSize: (width: Int, height: Int)? = (1024, 768)
  var linkBitsPerSecond: Double?
  var deliversVideo = true
  var channelAvailableOnAccept = true
  weak var surface: FakeSurface?
  private(set) var offers = 0
  private(set) var answers: [String] = []
  private(set) var closed = false

  init(capabilities: ScreenSharingCapabilities = [.control, .statistics]) { self.capabilities = capabilities }

  func offer() async throws -> String {
    offers += 1
    return "fixture offer"
  }
  func accept(_ answer: String) async throws {
    answers.append(answer)
    controlChannel.isAvailable = channelAvailableOnAccept
    if deliversVideo { surface?.present() }
  }
  func statistics() async -> [String: String] { [:] }
  func close() {
    closed = true
    controlChannel.close()
    frames.clear()
  }
}

/// The AppKit half of an endpoint without AppKit behavior: an empty view,
/// recorded input state, and a presentation the test triggers.
@MainActor
final class FakeSurface: ScreenSharingViewerSurface {
  let view = NSView()
  var onPresented: (() -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var onInput: ((ScreenSharingInputEvent) -> Void)?
  var onInputReleased: (() -> Void)?
  var onSizeChanged: ((CGSize, CGFloat) -> Void)?
  var inputFailureMessage: String?
  /// Whether `beginInput` succeeds; false models a refused focus or keyboard capture.
  var beginInputSucceeds = true
  private(set) var inputActive = false
  private(set) var presentations = 0
  private(set) var stopped = false

  func beginInput() -> Bool {
    guard beginInputSucceeds else { return false }
    inputActive = true
    return true
  }
  func endInput() { inputActive = false }
  func stop() { stopped = true }
  func present() {
    presentations += 1
    onPresented?()
  }
}

/// The Codevisor server's screen-sharing signaling as a scripted transport.
actor SharingTransport: ServerRequestTransport {
  nonisolated let started = TestSignal()
  nonisolated let releaseFirstStart = TestSignal()
  /// Signaled for every stop request, after it was recorded.
  nonisolated let stopped = TestSignal()
  private let blockFirstStart: Bool
  private let capabilitiesStatus: String
  private let heartbeatStatus: String
  private let restartStatus: String
  private let provider: String?
  private(set) var requests: [ServerScreenSharingRequest] = []
  private(set) var stopWasCancelled = false

  init(
    blockFirstStart: Bool = false, capabilitiesStatus: String = "available", heartbeatStatus: String = "viewing",
    restartStatus: String = "connecting", provider: String? = nil
  ) {
    self.blockFirstStart = blockFirstStart
    self.capabilitiesStatus = capabilitiesStatus
    self.heartbeatStatus = heartbeatStatus
    self.restartStatus = restartStatus
    self.provider = provider
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let payload = try JSONDecoder().decode(ServerScreenSharingRequest.self, from: request.httpBody ?? Data())
    requests.append(payload)
    let reply: ServerScreenSharingReply
    switch payload.operation {
    case .capabilities:
      reply = .init(status: capabilitiesStatus, displays: [ScreenSharingViewerFixtures.display], provider: provider)
    case .start, .restart:
      let first = requests.filter { $0.operation == .start }.count == 1
      started.signal()
      if first, blockFirstStart { await releaseFirstStart.wait() }
      reply = .init(status: payload.operation == .restart ? restartStatus : "connecting", answer: "fixture answer")
    case .heartbeat: reply = .init(status: heartbeatStatus)
    case .setScale: reply = .init(status: "unsupported")
    case .stop:
      stopWasCancelled = stopWasCancelled || Task.isCancelled
      reply = .init(status: "stopped")
      stopped.signal()
    }
    return (
      try JSONEncoder().encode(reply),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

/// Events observed from one or more backend streams, in arrival order.
@MainActor
@Observable
final class ScreenSharingEventLog {
  private(set) var events: [ScreenSharingViewerEvent] = []
  private(set) var finished = 0
  var endpoints: [ScreenSharingViewerEndpoint] {
    events.compactMap { if case .opened(let endpoint) = $0 { endpoint } else { nil } }
  }
  func append(_ event: ScreenSharingViewerEvent) { events.append(event) }
  func finish() { finished += 1 }
}

/// The native backend over the scripted transport, a virtual clock and fake media.
@MainActor
final class NativeBackendHarness {
  let transport: SharingTransport
  let clock = TestClock()
  let log = ScreenSharingEventLog()
  private(set) var sessions: [FakeMediaSession] = []
  private(set) var surfaces: [FakeSurface] = []
  var configureSession: (FakeMediaSession) -> Void = { _ in }
  private(set) var backend: ScreenSharingViewerBackend!
  private var consumers: [Task<Void, Never>] = []

  init(
    transport: SharingTransport = SharingTransport(),
    vncOpen: @escaping ScreenSharingViewerBackend.NativeVNCOpen = { _ in
      throw RFBError.transport("No VNC display in this test.")
    },
    target: String? = nil
  ) {
    self.transport = transport
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let clock = clock
    backend = .native(
      client: client, workspaceId: UUID(), paneId: UUID(), sleep: { try await clock.sleep(for: $0) },
      makeSession: { [unowned self] _ in
        let session = FakeMediaSession()
        configureSession(session)
        sessions.append(session)
        return session
      },
      makeSurface: { [unowned self] session in
        let surface = FakeSurface()
        (session as? FakeMediaSession)?.surface = surface
        surfaces.append(surface)
        return surface
      },
      vncOpen: vncOpen, target: target)
  }

  /// Consumes one connection's events into the log until the stream ends or the consumer is cancelled.
  @discardableResult
  func connect(_ display: String = "display") -> Task<Void, Never> {
    let consumer = Task { @MainActor [self] in
      for await event in await backend.connect(display) { log.append(event) }
      log.finish()
    }
    consumers.append(consumer)
    return consumer
  }

  func cancelConsumers() async {
    for consumer in consumers { consumer.cancel() }
    for consumer in consumers { await consumer.value }
  }
}
