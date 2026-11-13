import AppKit
import CodevisorClient
import ScreenSharing
import ScreenSharingV2
import CodevisorTestSupport
import CoreVideo
import Foundation
import Observation
@testable import CodevisorCoreMac

enum ScreenSharingViewerFixtures {
  static let display = ServerScreenSharingDisplay(id: "display", name: "Display", width: 1920, height: 1080)
  static let second = ServerScreenSharingDisplay(id: "second", name: "Second", width: 1280, height: 720)
  static let viewerMedia = ServerScreenSharingMediaAddress(
    endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: ["192.168.1.2:4433"])
  static let mediaGrant = ServerScreenSharingMediaGrant(
    endpointId: String(repeating: "b", count: 64), relayUrl: "https://relay.example.test",
    directAddrs: ["192.168.1.3:4433"], token: "fixture token")
}

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
final class FakeSurface: ScreenSharingViewerSurface {
  let view = NSView()
  var onFocusChanged: ((Bool) -> Void)?
  var onInput: ((ScreenSharingInputEvent) -> Void)?
  var onInputReleased: (() -> Void)?
  var onKeyboardReturned: (() -> Void)?
  var onSizeChanged: ((CGSize, CGFloat) -> Void)?
  var onScreenHighDynamicRangeChanged: ((Bool) -> Void)?
  var inputFailureMessage: String?
  var capturesSystemShortcuts = true
  var dropsInjectedInput = true
  var beginInputSucceeds = true
  private(set) var inputActive = false
  private(set) var stopped = false
  private(set) var videoShowsPointer: Bool?

  func setVideoShowsPointer(_ shows: Bool) { videoShowsPointer = shows }

  func beginInput() -> Bool {
    guard beginInputSucceeds else { return false }
    inputActive = true
    return true
  }
  func endInput() { inputActive = false }
  func stop() { stopped = true }
}

actor SharingTransport: ServerRequestTransport {
  nonisolated let started = TestSignal()
  nonisolated let releaseFirstStart = TestSignal()
  nonisolated let stopped = TestSignal()
  private let blockFirstStart: Bool
  private let capabilitiesStatus: String
  private let heartbeatStatus: String
  private var heartbeatReplies: [ServerScreenSharingReply]
  private let startStatus: String
  private let restartStatus: String
  private let provider: String?
  private let startNotice: String?
  private let engines: [String]?
  private(set) var requests: [ServerScreenSharingRequest] = []
  private(set) var stopWasCancelled = false

  init(
    blockFirstStart: Bool = false, capabilitiesStatus: String = "available", heartbeatStatus: String = "viewing",
    startStatus: String = "connecting", restartStatus: String = "connecting", provider: String? = nil,
    heartbeatReplies: [ServerScreenSharingReply] = [], startNotice: String? = nil, engines: [String]? = ["v2"]
  ) {
    self.engines = engines
    self.startStatus = startStatus
    self.heartbeatReplies = heartbeatReplies
    self.startNotice = startNotice
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
      var capabilities = ServerScreenSharingReply(
        status: capabilitiesStatus, displays: [ScreenSharingViewerFixtures.display], provider: provider)
      capabilities.engines = engines
      reply = capabilities
    case .start, .restart:
      let first = requests.filter { $0.operation == .start }.count == 1
      started.signal()
      if first, blockFirstStart { await releaseFirstStart.wait() }
      let status = payload.operation == .restart ? restartStatus : startStatus
      var started = ServerScreenSharingReply(status: status, message: startNotice)
      if status == "connecting" { started.media = ScreenSharingViewerFixtures.mediaGrant }
      reply = started
    case .heartbeat:
      reply = heartbeatReplies.isEmpty ? .init(status: heartbeatStatus) : heartbeatReplies.removeFirst()
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
    target: String? = nil,
    heartbeatInterval: Duration = .seconds(8),
    v2: V2 = V2(),
    tunnel: ServerRequestGate? = nil
  ) {
    self.transport = transport
    let client = CodevisorServerClient(
      config: .init(requestTransport: transport), requestGate: tunnel, machineId: tunnel == nil ? nil : Self.host)
    let clock = clock
    let connector = ScreenSharingV2Connector(
      address: { v2.hasAddress ? ScreenSharingViewerFixtures.viewerMedia : nil },
      connect: { [unowned self] grant in
        v2.grants.append(grant)
        if v2.failsConnect || v2.failingConnects > 0 {
          v2.failingConnects -= 1
          throw RFBError.transport("No route to the host in this test.")
        }
        return makeSession()
      })
    backend = .native(
      client: client, workspaceId: UUID(), paneId: UUID(), v2: connector, sleep: { try await clock.sleep(for: $0) },
      now: { clock.now },
      makeSurface: { [unowned self] _ in
        let surface = FakeSurface()
        surfaces.append(surface)
        return surface
      },
      vncOpen: vncOpen, target: target, heartbeatInterval: heartbeatInterval)
  }

  private func makeSession() -> FakeMediaSession {
    let session = FakeMediaSession()
    configureSession(session)
    sessions.append(session)
    return session
  }

  static let host = "host"

  @MainActor
  final class V2 {
    var hasAddress = true
    var failsConnect = false
    var failingConnects = 0
    var grants: [ServerScreenSharingMediaGrant] = []
  }

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
