import CodevisorScreenSharing
import Foundation
import ScreenSharingRFB

/// A `ScreenSharingViewingSession` over one connected `RFBClient`: every
/// framebuffer update becomes a BGRA frame in the mailbox, control and
/// clipboard ride the host emulator's local channels, and the read loop's
/// end is reported through `onConnectionChanged` ("disconnected" for a lost
/// or closed socket, "failed" with `failure` set for a protocol error).
@MainActor
public final class VNCScreenSharingSession: ScreenSharingViewingSession {
  public let capabilities: ScreenSharingCapabilities = [.control, .clipboard]
  public let frames = ScreenSharingFrameMailbox()
  public let metrics: ScreenSharingMetrics
  public var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { emulator.controlChannel }
  public var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { emulator.clipboardChannel }
  public private(set) var failure: String?
  public var onConnectionChanged: ((String) -> Void)?
  let client: RFBClient
  private let translator: VNCInputTranslator
  private let emulator: VNCHostEmulator
  private let publisher = VNCFramePublisher()
  private let outbox: AsyncStream<RFBClientMessage>.Continuation
  private let sender: Task<Void, Never>
  /// The read loop; its value is the error that ended it.
  private var run: Task<any Error, Never>!
  public private(set) var closed = false

  public init(
    client: RFBClient, parameters: RFBServerParameters, metrics: ScreenSharingMetrics = ScreenSharingMetrics(),
    keys: VNCKeyTranslator = VNCKeyTranslator()
  ) {
    self.client = client
    self.metrics = metrics
    translator = VNCInputTranslator(width: parameters.width, height: parameters.height, keys: keys)
    // Input arrives synchronously and often; one task writes it in order.
    let (messages, continuation) = AsyncStream<RFBClientMessage>.makeStream()
    outbox = continuation
    sender = Task {
      for await message in messages {
        guard (try? await client.send(message)) != nil else { break }
      }
    }
    emulator = VNCHostEmulator(translator: translator) { continuation.yield($0) }
    metrics.label("decoder", "RFB")
    metrics.label("videoSize", "\(parameters.width) × \(parameters.height)")
    metrics.label("serverName", parameters.name)
    let publisher = publisher
    let frames = frames
    run = Task { [weak self] in
      do {
        try await client.run(
          onUpdate: { framebuffer, update in
            publisher.publish(framebuffer, to: frames, metrics: metrics)
            metrics.increment("vncRectangles", by: update.rectangles.count)
            if update.resized {
              let width = framebuffer.width, height = framebuffer.height
              Task { @MainActor in self?.resized(width: width, height: height) }
            }
          },
          onEvent: { event in
            Task { @MainActor in self?.handle(event) }
          })
      } catch {
        Task { @MainActor in self?.ended(with: error) }
        return error
      }
    }
  }

  /// The error that ended the read loop, once it has.
  public func outcome() async -> any Error { await run.value }

  public func statistics() async -> [String: String] { [:] }

  public func close() {
    guard !closed else { return }
    closed = true
    emulator.close()
    outbox.finish()
    sender.cancel()
    client.close()
    frames.clear()
    onConnectionChanged = nil
  }

  private func resized(width: Int, height: Int) {
    translator.width = width
    translator.height = height
    metrics.label("videoSize", "\(width) × \(height)")
  }

  private func handle(_ event: RFBServerEvent) {
    switch event {
    case .bell: metrics.increment("vncBells")
    case .serverCutText(let text):
      emulator.serverCutText(text)
      metrics.increment("vncServerCutTexts")
    }
  }

  private func ended(with error: any Error) {
    guard !closed else { return }
    switch error as? RFBError {
    case .connectionClosed, .transport:
      onConnectionChanged?("disconnected")
    default:
      failure = error.localizedDescription
      metrics.label("vncFailure", error.localizedDescription)
      onConnectionChanged?("failed")
    }
  }
}

/// TCP, handshake and authentication against a VNC server; the client is
/// closed on any failure. The parameters name and size the desktop.
public enum VNCConnection {
  /// TCP, handshake and authentication; the client is closed on any failure.
  public static func open(
    host: String, port: UInt16, password: String?
  ) async throws -> (
    client: RFBClient, outcome: RFBHandshake.Outcome
  ) {
    try await open(transport: try await RFBNetworkTransport.connect(host: host, port: port), password: password)
  }

  /// Handshake and authentication over a connected transport; the client
  /// (and with it the transport) is closed on any failure.
  public static func open(
    transport: any RFBTransport, password: String?
  ) async throws -> (
    client: RFBClient, outcome: RFBHandshake.Outcome
  ) {
    let client = try RFBClient(transport: transport)
    do {
      return (client, try await client.connect(password: password))
    } catch {
      client.close()
      throw error
    }
  }
}
