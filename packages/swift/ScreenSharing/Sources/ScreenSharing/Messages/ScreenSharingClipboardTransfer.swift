import Foundation

@MainActor
public final class ScreenSharingClipboardTransfer {
  public typealias Content = ScreenSharingClipboardContent
  public var onFinished: ((String?) -> Void)?
  public var richContent = false
  public var isBusy: Bool { outgoing != nil || incoming != nil || requested != nil }
  private let send: (ScreenSharingClipboardMessage) -> Bool
  private let now: () -> TimeInterval
  private let canReceiveUnsolicited: () -> Bool
  private let read: (Bool) throws -> Content
  private let write: (Content) throws -> Void
  private var requested: UUID?
  private var outgoing: Outgoing?
  private var incoming: Incoming?
  private var deadline: TimeInterval = 0
  private struct Outgoing {
    let id: UUID; let data: Data; let chunkBytes: Int; let window: Int
    var sent = 0; var acknowledged = 0; var awaitingEnd = false
    var chunks: Int { (data.count + chunkBytes - 1) / chunkBytes }
  }
  private struct Incoming { let id: UUID; let count: Int; let richContent: Bool; var data = Data(); var nextIndex = 0 }

  public init(
    send: @escaping (ScreenSharingClipboardMessage) -> Bool,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    canReceiveUnsolicited: @escaping () -> Bool = { false },
    read: @escaping (_ richContent: Bool) throws -> Content, write: @escaping (Content) throws -> Void
  ) {
    self.send = send; self.now = now; self.canReceiveUnsolicited = canReceiveUnsolicited
    self.read = read; self.write = write
  }

  public func requestContent() {
    guard !isBusy else { return }
    let id = UUID(); requested = id; extendDeadline()
    transmit(.read(id: id))
  }
  public func sendContent(_ content: Content) {
    guard !isBusy else { return }
    start(content, id: UUID())
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
      do { start(try read(richContent), id: id) } catch { reject(id, error.localizedDescription) }
    case .begin(let id, let count, let rich):
      let richContent = rich == true
      let limit =
        richContent ? ScreenSharingClipboardMessage.maximumContentBytes : ScreenSharingClipboardMessage.maximumTextBytes
      guard outgoing == nil, incoming == nil,
        requested == id || (requested == nil && canReceiveUnsolicited()),
        (0...limit).contains(count)
      else { reject(id, "Clipboard transfer was not requested or is too large."); return }
      incoming = Incoming(id: id, count: count, richContent: richContent); extendDeadline()
      transmit(.ack(id: id, nextIndex: 0))
    case .chunk(let id, let index, let data):
      guard var current = incoming, current.id == id else { return }
      let chunkBytes =
        current.richContent ? ScreenSharingClipboardMessage.richChunkBytes : ScreenSharingClipboardMessage.chunkBytes
      guard index == current.nextIndex, !data.isEmpty, data.count <= chunkBytes,
        current.data.count + data.count <= current.count
      else { rejectCurrent(id, "Invalid clipboard chunk."); return }
      current.data.append(data); current.nextIndex += 1; incoming = current; extendDeadline()
      transmit(.ack(id: id, nextIndex: current.nextIndex))
    case .ack(let id, let index):
      guard var current = outgoing, current.id == id, !current.awaitingEnd else { return }
      guard index == current.acknowledged, index <= current.sent else {
        cancel(reason: "Invalid clipboard acknowledgment."); return
      }
      current.acknowledged += 1; outgoing = current; extendDeadline()
      if index == current.chunks {
        current.awaitingEnd = true; outgoing = current
        transmit(.end(id: id))
        return
      }
      while current.sent < current.chunks, current.sent - index < current.window {
        let offset = current.sent * current.chunkBytes
        let end = min(current.data.count, offset + current.chunkBytes)
        let chunk = ScreenSharingClipboardMessage.chunk(
          id: id, index: current.sent, data: current.data.subdata(in: offset..<end))
        current.sent += 1; outgoing = current
        guard transmit(chunk) else { return }
      }
    case .end(let id):
      guard let current = incoming, current.id == id else { return }
      guard requested == id || canReceiveUnsolicited() else {
        rejectCurrent(id, "Clipboard transfer is no longer authorized."); return
      }
      guard current.data.count == current.count, let content = Self.content(current) else {
        rejectCurrent(id, "Clipboard data was incomplete or not valid."); return
      }
      do {
        try write(content)
        _ = send(.result(id: id, error: nil))
        finish(nil)
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

  private static func content(_ incoming: Incoming) -> Content? {
    if incoming.richContent { return try? Content.unarchived(incoming.data) }
    return String(data: incoming.data, encoding: .utf8).map(Content.init(text:))
  }

  private func start(_ content: Content, id: UUID) {
    let data: Data
    if richContent {
      guard content.byteCount <= ScreenSharingClipboardMessage.maximumContentBytes,
        let archive = try? content.archived(),
        archive.count <= ScreenSharingClipboardMessage.maximumContentBytes
      else { refuse(id, "The clipboard must be 32 MB or smaller."); return }
      data = archive
    } else {
      guard let text = content.text else { refuse(id, "The clipboard does not contain plain text."); return }
      data = Data(text.utf8)
      guard data.count <= ScreenSharingClipboardMessage.maximumTextBytes else {
        refuse(id, "Clipboard text must be 64 KiB or smaller."); return
      }
    }
    outgoing = Outgoing(
      id: id, data: data,
      chunkBytes: richContent ? ScreenSharingClipboardMessage.richChunkBytes : ScreenSharingClipboardMessage.chunkBytes,
      window: richContent ? ScreenSharingClipboardMessage.richWindow : 1)
    extendDeadline()
    transmit(.begin(id: id, bytes: data.count, richContent: richContent ? true : nil))
  }
  private func extendDeadline() { deadline = now() + 10 }
  @discardableResult
  private func transmit(_ message: ScreenSharingClipboardMessage) -> Bool {
    if send(message) { return true }
    finish("The clipboard channel is unavailable. Reconnect and try again.")
    return false
  }
  private func refuse(_ id: UUID, _ error: String) { reject(id, error); onFinished?(error) }
  private func reject(_ id: UUID, _ error: String) { _ = send(.result(id: id, error: String(error.prefix(256)))) }
  private func rejectCurrent(_ id: UUID, _ error: String) {
    finish(error); reject(id, error)
  }
  private func finish(_ error: String?) {
    outgoing = nil; incoming = nil; requested = nil
    onFinished?(error)
  }
}
