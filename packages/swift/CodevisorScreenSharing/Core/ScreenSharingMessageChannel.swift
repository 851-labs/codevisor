import Foundation

/// An ordered, reliable, bounded channel of typed messages between the two
/// ends of a screen-sharing session. The native transport implements it with
/// one negotiated SCTP data channel per protocol; tests and local backends use
/// `ScreenSharingLocalChannel`. Control, clipboard and refresh protocols are
/// written against this contract and never learn which transport carries them.
///
/// Delivery and availability callbacks arrive on the main actor. `send`
/// returns false — and the channel may close itself — whenever the message
/// cannot be carried right now; callers treat that as a transport failure.
@MainActor
public protocol ScreenSharingMessageChannel<Message>: AnyObject {
  associatedtype Message: Sendable
  var isAvailable: Bool { get }
  var onMessage: ((Message) -> Void)? { get set }
  var onAvailabilityChanged: ((Bool) -> Void)? { get set }
  @discardableResult func send(_ message: Message) -> Bool
  func close()
}

/// Two connected in-memory ends. Delivery hops through `hop` exactly like the
/// native channel hops WebRTC callbacks onto the main actor, so a message sent
/// from inside a delivery callback is never delivered reentrantly. Tests pass
/// a hop they drain explicitly; the default schedules a main-actor task.
@MainActor
public final class ScreenSharingLocalChannel<Message: Sendable>: ScreenSharingMessageChannel {
  public typealias Hop = @Sendable (_ work: @escaping @Sendable @MainActor () -> Void) -> Void

  public var onMessage: ((Message) -> Void)?
  public var onAvailabilityChanged: ((Bool) -> Void)?
  public var isAvailable: Bool { !closed && peer?.closed == false }
  /// Messages accepted by `send` on this end, in order (diagnostic).
  public private(set) var sentCount = 0
  private weak var peer: ScreenSharingLocalChannel<Message>?
  private let hop: Hop
  private var closed = false

  private init(hop: @escaping Hop) { self.hop = hop }

  /// A connected pair. Both ends are available until either closes.
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
    sentCount += 1
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
