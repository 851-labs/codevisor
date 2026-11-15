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
    var settleAfter: Duration?
  }

  public var onMessage: ((Message) -> Void)?
  public var onAvailabilityChanged: ((Bool) -> Void)?
  public var isAvailable: Bool { stream != nil && !closed }
  private let codec: Codec
  private let bufferedBytes: Int
  private let datagrams: Datagrams?
  private let queuedBytes = Atomic(0)
  private var stream: (any ScreenSharingV2MessageStream)?
  private let outbox = Mutex<AsyncStream<Data>.Continuation?>(nil)
  private var tasks: [Task<Void, Never>] = []
  private var settling: Task<Void, Never>?
  private var closed = false

  init(codec: Codec, bufferedBytes: Int, datagrams: Datagrams? = nil) {
    self.codec = codec
    self.bufferedBytes = bufferedBytes
    self.datagrams = datagrams
  }

  func attach(_ stream: any ScreenSharingV2MessageStream) {
    guard !closed, self.stream == nil else { return }

    self.stream = stream
    let (queued, continuation) = AsyncStream<Data>.makeStream()
    outbox.withLock { $0 = continuation }
    tasks = [
      Task { [weak self] in
        let delivered = await Self.deliver(queued, over: stream) { [weak self] in
          self?.queuedBytes.subtract($0, ordering: .relaxed)
        }
        if !delivered { self?.fail() }
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
    if let datagrams, datagrams.carries(message) {
      if let settleAfter = datagrams.settleAfter { settle(data, after: settleAfter) }
      return datagrams.send(data)
    }

    return enqueue(data)
  }

  @discardableResult
  public nonisolated func sendFromAnyThread(_ message: Message) -> Bool {
    guard datagrams?.carries(message) != true, let data = try? codec.encode(message) else { return false }

    return outbox.withLock { outbox in
      guard let outbox else { return false }
      guard queuedBytes.add(data.count, ordering: .relaxed).newValue <= bufferedBytes else {
        queuedBytes.subtract(data.count, ordering: .relaxed)
        return false
      }

      outbox.yield(data)
      return true
    }
  }

  @concurrent
  private nonisolated static func deliver(
    _ queued: AsyncStream<Data>, over stream: any ScreenSharingV2MessageStream, onSent: @Sendable (Int) -> Void
  ) async -> Bool {
    for await data in queued {
      do { try await stream.send(data) } catch { return false }
      onSent(data.count)
    }
    await stream.finish()
    return true
  }

  private func settle(_ data: Data, after delay: Duration) {
    settling?.cancel()
    settling = Task { [weak self] in
      guard (try? await Task.sleep(for: delay)) != nil, let self, self.isAvailable else { return }

      self.enqueue(data)
    }
  }

  @discardableResult
  private func enqueue(_ data: Data) -> Bool {
    let queued = queuedBytes.add(data.count, ordering: .relaxed).newValue
    guard queued <= bufferedBytes else {
      fail()
      return false
    }

    outbox.withLock { _ = $0?.yield(data) }
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
    outbox.withLock {
      $0?.finish()
      $0 = nil
    }
    settling?.cancel()
    tasks.last?.cancel()
    let changed = onAvailabilityChanged
    onAvailabilityChanged = nil
    onMessage = nil
    changed?(false)
  }
}

extension ScreenSharingV2Channel: ScreenSharingBackgroundSending {}
