import Foundation
import ScreenSharing
import Synchronization

@MainActor
public final class ScreenSharingV2Channel<Message: Sendable>: ScreenSharingMessageChannel {
  public struct Codec: Sendable {
    let encode: @Sendable (Message) throws -> Data
    let decode: @Sendable (Data) throws -> Message
  }

  public struct Datagrams: Sendable {
    let carries: @Sendable (Message) -> Bool
    let send: @Sendable (Data) -> Bool
  }

  public var onMessage: ((Message) -> Void)?
  public var onAvailabilityChanged: ((Bool) -> Void)?
  public var isAvailable: Bool { stream != nil && !closed }
  private let codec: Codec
  private let bufferedBytes: Int
  private let datagrams: Datagrams?
  private let queuedBytes = Atomic(0)
  private var stream: (any ScreenSharingV2MessageStream)?
  private var outbox: AsyncStream<Data>.Continuation?
  private var tasks: [Task<Void, Never>] = []
  private var closed = false

  init(codec: Codec, bufferedBytes: Int, datagrams: Datagrams? = nil) {
    self.codec = codec
    self.bufferedBytes = bufferedBytes
    self.datagrams = datagrams
  }

  func attach(_ stream: any ScreenSharingV2MessageStream) {
    guard !closed, self.stream == nil else { return }

    self.stream = stream
    let (outbox, continuation) = AsyncStream<Data>.makeStream()
    self.outbox = continuation
    tasks = [
      Task { [weak self] in
        for await data in outbox {
          do {
            try await stream.send(data)
          } catch {
            self?.fail()
            return
          }
          self?.queuedBytes.subtract(data.count, ordering: .relaxed)
        }
        await stream.finish()
      },
      Task { [weak self, codec] in
        do {
          while let data = try await stream.receive() {
            guard let self, !self.closed else { return }

            self.onMessage?(try codec.decode(data))
          }
        } catch {}
        self?.fail()
      },
    ]
    onAvailabilityChanged?(true)
  }

  @discardableResult
  public func send(_ message: Message) -> Bool {
    guard isAvailable, let data = try? codec.encode(message) else { return false }
    if let datagrams, datagrams.carries(message) { return datagrams.send(data) }

    let queued = queuedBytes.add(data.count, ordering: .relaxed).newValue
    guard queued <= bufferedBytes else {
      fail()
      return false
    }

    outbox?.yield(data)
    return true
  }

  func receiveDatagram(_ data: Data) {
    guard isAvailable, let message = try? codec.decode(data) else { return }

    onMessage?(message)
  }

  public func close() {
    fail()
  }

  private func fail() {
    guard !closed else { return }

    closed = true
    outbox?.finish()
    outbox = nil
    tasks.last?.cancel()
    let changed = onAvailabilityChanged
    onAvailabilityChanged = nil
    onMessage = nil
    changed?(false)
  }
}
