import CoreVideo
import Foundation
import ScreenSharing

@MainActor
public final class ScreenSharingManualHop {
  private var queued: [@Sendable @MainActor () -> Void] = []

  public nonisolated init() {}

  public nonisolated func schedule(_ work: @escaping @Sendable @MainActor () -> Void) {
    MainActor.assumeIsolated { queued.append(work) }
  }

  public var isEmpty: Bool { queued.isEmpty }

  public func drain() {
    let batch = queued
    queued = []
    for work in batch { work() }
  }

  public func drainAll() {
    while !queued.isEmpty { drain() }
  }
}

@MainActor
public final class ScreenSharingLocalViewingSession: ScreenSharingViewingSession {
  public let capabilities: ScreenSharingCapabilities
  public let frames = ScreenSharingFrameMailbox()
  public let metrics = ScreenSharingMetrics()
  public private(set) var failure: String?
  public var onConnectionChanged: ((String) -> Void)?
  public private(set) var isClosed = false

  private let controlChannel: ScreenSharingLocalChannel<ScreenSharingControlMessage>?
  private let clipboardChannel: ScreenSharingLocalChannel<ScreenSharingClipboardMessage>?
  fileprivate var reportedStatistics: [String: String] = [:]

  public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { controlChannel }
  public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { clipboardChannel }

  private init(
    capabilities: ScreenSharingCapabilities,
    control: ScreenSharingLocalChannel<ScreenSharingControlMessage>?,
    clipboard: ScreenSharingLocalChannel<ScreenSharingClipboardMessage>?
  ) {
    self.capabilities = capabilities
    controlChannel = control
    clipboardChannel = clipboard
  }

  public static func connected(
    capabilities: ScreenSharingCapabilities = [.control, .clipboard, .statistics],
    hop: @escaping @Sendable (_ work: @escaping @Sendable @MainActor () -> Void) -> Void = { work in
      Task { @MainActor in work() }
    }
  ) -> (session: ScreenSharingLocalViewingSession, host: ScreenSharingLocalViewingHost) {
    let control =
      capabilities.contains(.control) ? ScreenSharingLocalChannel<ScreenSharingControlMessage>.pair(hop: hop) : nil
    let clipboard =
      capabilities.contains(.clipboard) ? ScreenSharingLocalChannel<ScreenSharingClipboardMessage>.pair(hop: hop) : nil
    let session = ScreenSharingLocalViewingSession(
      capabilities: capabilities, control: control?.0, clipboard: clipboard?.0)
    let host = ScreenSharingLocalViewingHost(
      session: session, control: control?.1, clipboard: clipboard?.1)
    return (session, host)
  }

  public func statistics() async -> [String: String] {
    guard capabilities.contains(.statistics), !isClosed else { return [:] }
    return reportedStatistics
  }

  public func close() {
    guard !isClosed else { return }
    isClosed = true
    frames.clear()
    controlChannel?.close()
    clipboardChannel?.close()
    onConnectionChanged = nil
  }

  fileprivate func deliver(_ frame: ScreenSharingVideoFrame) {
    guard !isClosed else { return }
    frames.put(frame)
    metrics.increment("viewingSessionFrames")
  }

  fileprivate func report(connection state: String) {
    guard !isClosed else { return }
    metrics.label("viewingSessionConnection", state)
    onConnectionChanged?(state)
  }

  fileprivate func fail(_ message: String) {
    guard !isClosed, failure == nil else { return }
    failure = message
    metrics.label("viewingSessionFailure", message)
  }
}

@MainActor
public final class ScreenSharingLocalViewingHost {
  public let control: ScreenSharingLocalChannel<ScreenSharingControlMessage>?
  public let clipboard: ScreenSharingLocalChannel<ScreenSharingClipboardMessage>?
  private weak var session: ScreenSharingLocalViewingSession?

  fileprivate init(
    session: ScreenSharingLocalViewingSession,
    control: ScreenSharingLocalChannel<ScreenSharingControlMessage>?,
    clipboard: ScreenSharingLocalChannel<ScreenSharingClipboardMessage>?
  ) {
    self.session = session
    self.control = control
    self.clipboard = clipboard
  }

  public func deliver(_ frame: ScreenSharingVideoFrame) { session?.deliver(frame) }

  public func deliverFrame(identity: Int64) {
    var pixel: CVPixelBuffer?
    CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel)
    guard let pixel else { preconditionFailure("A 2x2 BGRA buffer must be allocatable.") }
    deliver(ScreenSharingVideoFrame(pixelBuffer: pixel, timestampNs: identity, sourceTimestampNs: identity))
  }

  public func report(connection state: String) { session?.report(connection: state) }

  public func fail(_ message: String) { session?.fail(message) }

  public func publish(statistics: [String: String]) { session?.reportedStatistics = statistics }
}
