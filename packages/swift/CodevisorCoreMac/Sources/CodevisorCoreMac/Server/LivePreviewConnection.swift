//  A chat agent's live view from its server: which of Browser Use and
//  Computer Use it touched last, and the tab it drives through Browser Use.
//  The server streams that tab's viewport as JPEGs (a CDP screencast, so it
//  works for the built-in browser, managed Chromium, and the user's Chrome
//  alike); this connection follows its status and feeds decoded frames to a
//  viewer, the same surface the Computer Use preview renders.

import CodevisorCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Observation
import ScreenSharing

@MainActor
@Observable
public final class LivePreviewConnection {
  public enum State: String, Equatable, Sendable {
    /// The agent hasn't used the browser in this chat.
    case inactive
    case active
    case idle
    case stopped
  }

  public struct Status: Equatable, Sendable {
    public let state: State
    public let title: String
    public let url: String
  }

  public enum Tool: String, Equatable, Sendable {
    case browser
    case computer
  }

  /// The browser tab's status; nil until the server first answers.
  public private(set) var status: Status?
  /// The tool the agent touched last; nil until it touches one.
  public private(set) var lastUsedTool: Tool?
  /// False while the socket is down and reconnecting.
  public private(set) var isConnected = false
  /// Stops the tab's frames while its viewer is out of sight, without
  /// dropping the viewer or the status.
  public var isPaused = false {
    didSet {
      guard isPaused != oldValue, sink != nil else { return }
      if isPaused { send(["type": "unwatch"]) } else { watch() }
    }
  }

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let chatSession: UUID
  @ObservationIgnored private var socket: (any ServerWebSocketConnecting)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var sink: LivePreviewFrameSink?
  @ObservationIgnored private var dimension: CGFloat = 1280

  public init(client: any CodevisorServerClienting, chatSession: UUID) {
    self.client = client
    self.chatSession = chatSession
  }

  /// Connects and stays connected, reconnecting after drops, until `stop`.
  public func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      var delay: Duration = .milliseconds(500)
      while !Task.isCancelled {
        guard let self else { return }
        let connected = await self.runConnection()
        if Task.isCancelled { return }
        delay = connected ? .milliseconds(500) : min(delay * 2, .seconds(15))
        try? await Task.sleep(for: delay)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    isConnected = false
  }

  /// A viewer of the agent's tab. Frames flow while it's attached; call
  /// `detach()` on it to stop them. Nil when Metal is unavailable.
  public func makeViewer(title: String) -> ComputerUseLivePreviewViewer? {
    let mailbox = ScreenSharingFrameMailbox()
    let surface: ComputerUseLivePreviewSurface
    do {
      surface = try ComputerUseLivePreviewSurface(mailbox: mailbox, metrics: ScreenSharingMetrics())
    } catch {
      Log.computerUse.error(
        "Unable to create a Browser Use live preview: \(error.localizedDescription, privacy: .public)")
      return nil
    }
    let sink = LivePreviewFrameSink(mailbox: mailbox)
    self.sink = sink
    let viewer = ComputerUseLivePreviewViewer(title: title, phase: .live) { [weak self, weak sink] in
      guard let self, self.sink === sink else { return }
      self.sink = nil
      self.send(["type": "unwatch"])
    }
    viewer.onDisplayDimension = { [weak self] dimension in
      guard let self, abs(self.dimension - dimension) >= 1 else { return }
      self.dimension = dimension
      self.watch()
    }
    viewer.install(surface)
    watch()
    return viewer
  }

  /// One connection's lifetime. Returns whether it ever connected.
  private func runConnection() async -> Bool {
    let socket: any ServerWebSocketConnecting
    do {
      socket = try client.livePreviewSocket(sessionId: chatSession)
    } catch {
      return false
    }
    self.socket = socket
    var connected = false
    defer {
      if self.socket === socket { self.socket = nil }
      isConnected = false
      socket.cancel(with: .goingAway, reason: nil)
    }
    if sink != nil { watch() }
    while !Task.isCancelled {
      guard let message = try? await socket.receive() else { return connected }
      if !connected {
        connected = true
        isConnected = true
      }
      receive(message)
    }
    return connected
  }

  private func receive(_ message: ServerWebSocketMessage) {
    let data: Data
    switch message {
    case .data(let bytes): data = bytes
    case .string(let text): data = Data(text.utf8)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else { return }
    switch type {
    case "tool":
      guard let raw = object["tool"] as? String, let tool = Tool(rawValue: raw) else { return }
      if tool != lastUsedTool { lastUsedTool = tool }
    case "status":
      guard let raw = object["state"] as? String, let state = State(rawValue: raw) else { return }
      let next = Status(
        state: state, title: object["title"] as? String ?? "", url: object["url"] as? String ?? "")
      if next != status { status = next }
    case "frame":
      guard let encoded = object["data"] as? String else { return }
      sink?.decode(encoded)
    default:
      break
    }
  }

  private func watch() {
    guard !isPaused else { return }
    send(["type": "watch", "dimension": Double(dimension)])
  }

  private func send(_ message: [String: Any]) {
    guard let socket,
      let data = try? JSONSerialization.data(withJSONObject: message),
      let text = String(data: data, encoding: .utf8)
    else { return }
    Task { try? await socket.send(.string(text)) }
  }
}

/// Decodes JPEG frames off the main thread into BGRA pixel buffers for the
/// viewer's Metal surface. Keeps only the newest frame when decoding lags.
final class LivePreviewFrameSink: @unchecked Sendable {
  private let mailbox: ScreenSharingFrameMailbox
  private let queue = DispatchQueue(label: "com.codevisor.browser-preview-decode", qos: .userInitiated)
  private let lock = NSLock()
  private var pending: String?
  private var decoding = false

  init(mailbox: ScreenSharingFrameMailbox) {
    self.mailbox = mailbox
  }

  func decode(_ base64: String) {
    let start = lock.withLock { () -> Bool in
      pending = base64
      if decoding { return false }
      decoding = true
      return true
    }
    guard start else { return }
    queue.async { [self] in drain() }
  }

  private func drain() {
    while let next = lock.withLock({ () -> String? in
      let value = pending
      pending = nil
      if value == nil { decoding = false }
      return value
    }) {
      guard let data = Data(base64Encoded: next), let buffer = Self.pixelBuffer(jpeg: data) else { continue }
      let now = Int64(DispatchTime.now().uptimeNanoseconds)
      mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: now))
    }
  }

  static func pixelBuffer(jpeg: Data) -> CVPixelBuffer? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width, height = image.height
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        == kCVReturnSuccess,
      let buffer
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
