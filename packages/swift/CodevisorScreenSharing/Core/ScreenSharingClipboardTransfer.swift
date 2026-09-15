import Foundation

/// Stop-and-wait acknowledgments admit only one 2 KiB clipboard chunk at a time.
/// An explicit read authorizes exactly one incoming transfer on a viewer.
@MainActor
public final class ScreenSharingClipboardTransfer {
  public var onFinished: ((String?) -> Void)?
  public var isBusy: Bool { outgoing != nil || incoming != nil || requested != nil }
  private let send: (ScreenSharingClipboardMessage) -> Bool
  private let now: () -> TimeInterval
  private let canReceiveUnsolicited: () -> Bool
  private let read: () throws -> String
  private let write: (String) throws -> Void
  private var requested: UUID?
  private var outgoing: Outgoing?
  private var incoming: Incoming?
  private var deadline: TimeInterval = 0
  private struct Outgoing { let id: UUID; let data: Data; var nextIndex = 0; var awaitingEnd = false }
  private struct Incoming { let id: UUID; let count: Int; var data = Data(); var nextIndex = 0 }

  public init(
    send: @escaping (ScreenSharingClipboardMessage) -> Bool,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    canReceiveUnsolicited: @escaping () -> Bool = { false },
    read: @escaping () throws -> String, write: @escaping (String) throws -> Void
  ) {
    self.send = send; self.now = now; self.canReceiveUnsolicited = canReceiveUnsolicited
    self.read = read; self.write = write
  }

  public func requestText() {
    guard !isBusy else { return }
    let id = UUID(); requested = id; deadline = now() + 10
    transmit(.read(id: id))
  }
  public func sendText(_ text: String) {
    guard !isBusy else { return }
    start(text, id: UUID())
  }
  public func tick() {
    if isBusy, now() >= deadline { cancel(reason: "Clipboard transfer timed out. Try again.") }
  }
  public func cancel(reason: String? = nil) {
    let id = outgoing?.id ?? incoming?.id ?? requested
    guard id != nil else { return }
    finish(reason)
    if let id { _ = send(.cancel(id: id)) }
  }

  public func receive(_ message: ScreenSharingClipboardMessage) {
    tick()
    switch message {
    case .read(let id):
      guard !isBusy, canReceiveUnsolicited() else { reject(id, "Clipboard is unavailable or busy."); return }
      do { start(try read(), id: id) } catch { reject(id, error.localizedDescription) }
    case .begin(let id, let count):
      guard outgoing == nil, incoming == nil,
        requested == id || (requested == nil && canReceiveUnsolicited()),
        (0...ScreenSharingClipboardMessage.maximumTextBytes).contains(count)
      else { reject(id, "Clipboard transfer was not requested or is too large."); return }
      incoming = Incoming(id: id, count: count); deadline = now() + 10
      transmit(.ack(id: id, nextIndex: 0))
    case .chunk(let id, let index, let data):
      guard var current = incoming, current.id == id else { return }
      guard index == current.nextIndex, !data.isEmpty, data.count <= ScreenSharingClipboardMessage.chunkBytes,
        current.data.count + data.count <= current.count
      else { rejectCurrent(id, "Invalid clipboard chunk."); return }
      current.data.append(data); current.nextIndex += 1; incoming = current
      transmit(.ack(id: id, nextIndex: current.nextIndex))
    case .ack(let id, let index):
      guard var current = outgoing, current.id == id, !current.awaitingEnd else { return }
      guard index == current.nextIndex else { cancel(reason: "Invalid clipboard acknowledgment."); return }
      let offset = index * ScreenSharingClipboardMessage.chunkBytes
      if offset >= current.data.count {
        current.awaitingEnd = true; outgoing = current
        transmit(.end(id: id))
      } else {
        let end = min(current.data.count, offset + ScreenSharingClipboardMessage.chunkBytes)
        current.nextIndex += 1; outgoing = current
        transmit(.chunk(id: id, index: index, data: current.data.subdata(in: offset..<end)))
      }
    case .end(let id):
      guard let current = incoming, current.id == id else { return }
      guard requested == id || canReceiveUnsolicited() else {
        rejectCurrent(id, "Clipboard transfer is no longer authorized."); return
      }
      guard current.data.count == current.count, let text = String(data: current.data, encoding: .utf8) else {
        rejectCurrent(id, "Clipboard data was incomplete or not valid text."); return
      }
      do {
        try write(text)
        finish(nil)
        _ = send(.result(id: id, error: nil))
      } catch { rejectCurrent(id, error.localizedDescription) }
    case .result(let id, let error):
      guard outgoing?.id == id || requested == id else { return }
      guard error != nil || outgoing?.awaitingEnd == true else {
        cancel(reason: "Invalid clipboard completion."); return
      }
      finish(error)
    case .cancel(let id):
      if outgoing?.id == id || incoming?.id == id || requested == id { finish("Clipboard transfer was cancelled.") }
    }
  }

  private func start(_ text: String, id: UUID) {
    let data = Data(text.utf8)
    guard data.count <= ScreenSharingClipboardMessage.maximumTextBytes else {
      reject(id, "Clipboard text must be 64 KiB or smaller."); onFinished?("Clipboard text must be 64 KiB or smaller.");
      return
    }
    outgoing = Outgoing(id: id, data: data); deadline = now() + 10
    transmit(.begin(id: id, bytes: data.count))
  }
  private func transmit(_ message: ScreenSharingClipboardMessage) {
    if !send(message) { finish("The clipboard channel is unavailable. Reconnect and try again.") }
  }
  private func reject(_ id: UUID, _ error: String) { _ = send(.result(id: id, error: String(error.prefix(256)))) }
  private func rejectCurrent(_ id: UUID, _ error: String) {
    finish(error); reject(id, error)
  }
  private func finish(_ error: String?) {
    outgoing = nil; incoming = nil; requested = nil
    onFinished?(error)
  }
}
