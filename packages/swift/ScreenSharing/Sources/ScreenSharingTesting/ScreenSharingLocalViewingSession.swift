import Foundation
import ScreenSharing

/// Main-actor work a test releases explicitly, in place of the channel's default `Task` hop. It
/// makes delivery order observable: nothing arrives until `drain()`, and work queued during a drain
/// waits for the next one, exactly as the native channel's hop onto the main actor does.
@MainActor
public final class ScreenSharingManualHop {
  private var queued: [@Sendable @MainActor () -> Void] = []

  public nonisolated init() {}

  public nonisolated func schedule(_ work: @escaping @Sendable @MainActor () -> Void) {
    MainActor.assumeIsolated { queued.append(work) }
  }

  public var isEmpty: Bool { queued.isEmpty }

  /// Runs the work queued so far. Work queued by that work is left for the next drain.
  public func drain() {
    let batch = queued
    queued = []
    for work in batch { work() }
  }

  /// Runs queued work until nothing is left, for a flow whose replies queue more work.
  public func drainAll() {
    while !queued.isEmpty { drain() }
  }
}

/// A viewing session with no transport behind it: frames go straight into the viewer's mailbox and
/// the typed protocols ride `ScreenSharingLocalChannel` pairs. It exists so the session contract —
/// capabilities, frame delivery, control flow, a terminal media failure, transport state and an
/// idempotent close — can be exercised without WebRTC, and so a feature can be driven against a
/// session whose far end a test controls.
@MainActor
public final class ScreenSharingLocalViewingSession: ScreenSharingViewingSession {
  public let capabilities: ScreenSharingCapabilities
  public let frames = ScreenSharingFrameMailbox()
  public let metrics = ScreenSharingMetrics()
  public private(set) var failure: String?
  public var onConnectionChanged: ((String) -> Void)?
  /// Whether `close()` has run. Every other operation is a no-op afterwards.
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

  /// A connected pair: the session the viewer sees, and the far end a test drives. Channels exist
  /// only for the capabilities that were negotiated, which is how a backend without control or
  /// clipboard reports itself.
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

  /// Statistics worth showing, or nothing at all when the backend did not negotiate them. A closed
  /// session reports nothing: the transport it would have asked is gone.
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

/// The far end of a `ScreenSharingLocalViewingSession`: what the host would send and what the
/// transport would report. Everything it does is refused once the session has closed, so a test
/// cannot accidentally observe a callback after a terminal close.
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

  /// One decoded frame identified by `identity`, for a test that only compares identities.
  public func deliverFrame(identity: Int64) { deliver(ScreenSharingFrameSinkContract.frame(identity)) }

  public func report(connection state: String) { session?.report(connection: state) }

  public func fail(_ message: String) { session?.fail(message) }

  public func publish(statistics: [String: String]) { session?.reportedStatistics = statistics }
}
