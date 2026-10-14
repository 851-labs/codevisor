import Foundation

@MainActor
public protocol ScreenSharingMessageChannel<Message>: AnyObject {
  associatedtype Message: Sendable
  var isAvailable: Bool { get }
  var onMessage: ((Message) -> Void)? { get set }
  var onAvailabilityChanged: ((Bool) -> Void)? { get set }
  @discardableResult func send(_ message: Message) -> Bool
  func close()
}

@MainActor
public final class ScreenSharingLocalChannel<Message: Sendable>: ScreenSharingMessageChannel {
  public typealias Hop = @Sendable (_ work: @escaping @Sendable @MainActor () -> Void) -> Void

  public var onMessage: ((Message) -> Void)?
  public var onAvailabilityChanged: ((Bool) -> Void)?
  public var isAvailable: Bool { !closed && peer?.closed == false }
  private weak var peer: ScreenSharingLocalChannel<Message>?
  private let hop: Hop
  private var closed = false

  private init(hop: @escaping Hop) { self.hop = hop }

  public static func pair(
    hop: @escaping Hop = { work in Task { @MainActor in work() } }
  ) -> (ScreenSharingLocalChannel, ScreenSharingLocalChannel) {
    let a = ScreenSharingLocalChannel(hop: hop)
    let b = ScreenSharingLocalChannel(hop: hop)
    a.peer = b
    b.peer = a
    return (a, b)
  }

  @discardableResult
  public func send(_ message: Message) -> Bool {
    guard isAvailable, let peer else { return false }
    hop { [weak peer] in
      guard let peer, !peer.closed else { return }
      peer.onMessage?(message)
    }
    return true
  }

  public func close() {
    guard !closed else { return }
    closed = true
    let peer = peer
    onAvailabilityChanged?(false)
    onAvailabilityChanged = nil
    onMessage = nil
    hop { [weak peer] in
      guard let peer, !peer.closed else { return }
      peer.onAvailabilityChanged?(false)
    }
  }
}
