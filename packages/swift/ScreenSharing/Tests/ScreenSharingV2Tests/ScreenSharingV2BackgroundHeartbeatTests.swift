#if os(macOS)
  import CodevisorTestSupport
  import Foundation
  import Synchronization
  import Testing

  @testable import ScreenSharing
  @testable import ScreenSharingV2

  @MainActor
  @Suite("Control heartbeats without the main thread", .timeLimit(.minutes(1)))
  struct ScreenSharingV2BackgroundHeartbeatTests {
    private static let leaseLifetime: TimeInterval = 3

    @Test("A main thread blocked for 5 s does not lose the control lease")
    func keepsTheLeaseWhileTheMainThreadIsBlocked() async throws {
      let stream = RecordingMessageStream()
      let channel = Self.controlChannel()
      channel.attach(stream)
      defer { channel.close() }
      let host = ReplayedHost()
      let lease = try #require(host.grant())
      let forwarder = ScreenSharingInputForwarder(
        send: { channel.send($0) }, heartbeat: { channel.sendFromAnyThread(.heartbeat(lease: $0)) })
      forwarder.begin(lease: lease)
      defer { forwarder.end() }
      await stream.firstArrival.wait()
      let began = ContinuousClock.now

      Self.blockThisThread(for: 5)

      let ended = ContinuousClock.now
      let heartbeats = stream.sent.filter { $0.at <= ended }
      #expect(heartbeats.filter { $0.at > began }.count >= 4, "heartbeats left while nothing ran on the main thread")
      for heartbeat in heartbeats {
        host.now = (heartbeat.at - began) / .seconds(1)
        host.control.receive(try ScreenSharingControlMessage.decode(heartbeat.payload))
      }
      host.now = (ended - began) / .seconds(1)
      host.control.checkDeadline()
      #expect(host.control.lease == lease, "a host that revokes after 3 s without a heartbeat keeps this lease")
      #expect(host.revoked.isEmpty)
    }

    @Test("Without the background heartbeat, the same 3 s of silence costs the lease")
    func losesTheLeaseAfterThreeSilentSeconds() throws {
      let host = ReplayedHost()
      let lease = try #require(host.grant())
      host.now = Self.leaseLifetime
      host.control.receive(.heartbeat(lease: lease))
      #expect(host.control.lease == nil && host.revoked == [lease])
    }

    @Test("A message sent from any thread is refused before the channel opens, after it closes and over its budget")
    func refusesWhatItCannotQueue() async throws {
      let stream = RecordingMessageStream(holdsSends: true)
      let heartbeat = ScreenSharingControlMessage.heartbeat(lease: UUID())
      let channel = Self.controlChannel(bufferedBytes: try heartbeat.encoded().count + 1)
      #expect(!channel.sendFromAnyThread(heartbeat))

      channel.attach(stream)
      #expect(channel.sendFromAnyThread(heartbeat))
      #expect(!channel.sendFromAnyThread(heartbeat), "over the buffer budget it is refused")
      #expect(channel.isAvailable, "and the channel stays open")

      channel.close()
      stream.release()
      #expect(!channel.sendFromAnyThread(heartbeat))
    }

    @Test("The forwarder keeps a lease alive only between begin and end, and only when given a heartbeat")
    func keepsAliveOnlyWhileALeaseIsHeld() {
      let silent = ScreenSharingInputForwarder(send: { _ in true })
      silent.begin(lease: UUID())
      #expect(!silent.keepsLeaseAlive)

      let beating = ScreenSharingInputForwarder(send: { _ in true }, heartbeat: { _ in true })
      #expect(!beating.keepsLeaseAlive)
      beating.begin(lease: UUID())
      #expect(beating.keepsLeaseAlive)
      beating.end()
      #expect(!beating.keepsLeaseAlive && !beating.isActive)
    }

    @Test("The v2 control channel is one the viewer can hand its heartbeat to")
    func offersBackgroundSendingThroughTheChannelProtocol() {
      let channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage> = Self.controlChannel()
      #expect(channel is any ScreenSharingBackgroundSending<ScreenSharingControlMessage>)
    }

    @Test("A forwarder released without ending its lease stops keeping it alive")
    func stopsTheKeepAliveWhenReleased() async {
      let released = TestSignal()
      var forwarder: ScreenSharingInputForwarder? = ScreenSharingInputForwarder(
        send: { _ in true }, heartbeat: { [token = ReleaseToken(released)] _ in token.isAlive },
        heartbeatInterval: .seconds(3600))
      forwarder?.begin(lease: UUID())
      #expect(forwarder?.keepsLeaseAlive == true)

      forwarder = nil

      await released.wait()
    }

    private static func controlChannel(
      bufferedBytes: Int = 16 * 1024
    ) -> ScreenSharingV2Channel<
      ScreenSharingControlMessage
    > {
      ScreenSharingV2Channel(
        codec: .init(encode: { try $0.encoded() }, decode: ScreenSharingControlMessage.decode),
        bufferedBytes: bufferedBytes)
    }

    private nonisolated static func blockThisThread(for seconds: TimeInterval) {
      Thread.sleep(forTimeInterval: seconds)
    }
  }

  @MainActor
  private final class ReplayedHost {
    var now: TimeInterval = 0
    private(set) var revoked: [UUID] = []
    private var granted: UUID?
    private(set) lazy var control = ScreenSharingHostControl(
      now: { [unowned self] in self.now }, availability: { nil }, inject: { _ in },
      send: { [unowned self] in
        if case .grant(_, let lease) = $0 { self.granted = lease }
        if case .revoked(let lease, _) = $0 { self.revoked.append(lease) }
        return true
      })

    func grant() -> UUID? {
      control.receive(.request(id: UUID()))
      return granted
    }
  }

  private final class ReleaseToken: Sendable {
    private let released: TestSignal

    init(_ released: TestSignal) {
      self.released = released
    }

    var isAlive: Bool { true }

    deinit { released.signal() }
  }

  private final class RecordingMessageStream: ScreenSharingV2MessageStream, Sendable {
    let firstArrival = TestSignal()
    private let arrivals = Mutex<[(at: ContinuousClock.Instant, payload: Data)]>([])
    private let finished = TestSignal()
    private let released = TestSignal()
    private let holdsSends: Bool

    init(holdsSends: Bool = false) {
      self.holdsSends = holdsSends
    }

    var sent: [(at: ContinuousClock.Instant, payload: Data)] { arrivals.withLock { $0 } }

    func release() { released.signal() }

    func send(_ payload: Data) async throws {
      if holdsSends { await released.wait() }
      arrivals.withLock { $0.append((ContinuousClock.now, payload)) }
      firstArrival.signal()
    }

    func receive() async throws -> Data? {
      await finished.wait()
      return nil
    }

    func finish() async { finished.signal() }
  }
#endif
