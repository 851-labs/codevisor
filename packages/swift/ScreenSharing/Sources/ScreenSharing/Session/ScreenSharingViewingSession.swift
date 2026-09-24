import Foundation

/// What a viewing session can do beyond delivering frames. The native WebRTC
/// backend offers all three; a backend without `.control` never shows a
/// Request Control affordance, and one without `.clipboard` hides the
/// clipboard menu. Capabilities are fixed for the session's lifetime.
public struct ScreenSharingCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  /// The lease-based control protocol is carried on `control`.
  public static let control = ScreenSharingCapabilities(rawValue: 1 << 0)
  /// The explicit text clipboard protocol is carried on `clipboard`.
  public static let clipboard = ScreenSharingCapabilities(rawValue: 1 << 1)
  /// `statistics()` returns transport statistics worth showing.
  public static let statistics = ScreenSharingCapabilities(rawValue: 1 << 2)
}

/// The remote pointer, for a backend that reports it separately from the
/// frames (VNC's Cursor and PointerPos pseudo-encodings): its shape, drawn
/// locally, and where the host moved it, in video pixels.
public enum ScreenSharingCursorUpdate: Sendable, Equatable {
  case shape(RFBCursorShape)
  case position(RFBPoint)
}

/// One live media session as the viewer sees it: decoded frames land in
/// `frames` (newest wins), optional protocols ride typed channels, and the
/// transport reports its state through `onConnectionChanged`. No SDP, no
/// signaling and no AppKit: the feature builds its own surface from the
/// mailbox and metrics, and the backend that created the session owns how it
/// was negotiated and when it must be replaced.
///
/// `close()` is terminal and idempotent. After it, the mailbox is cleared, the
/// channels are closed and no callback fires again.
@MainActor
public protocol ScreenSharingViewingSession: AnyObject {
  var capabilities: ScreenSharingCapabilities { get }
  var frames: ScreenSharingFrameMailbox { get }
  var metrics: ScreenSharingMetrics { get }
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { get }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { get }
  /// A terminal media failure (today: the hardware decoder); nil while healthy.
  var failure: String? { get }
  /// Transport state names as the backend reports them; "failed",
  /// "disconnected" and "closed" are the ones the viewer acts on.
  var onConnectionChanged: ((String) -> Void)? { get set }
  func statistics() async -> [String: String]
  func close()
  /// The remote pointer's shape and host-side moves; only backends that
  /// report the pointer separately set it (the default ignores it).
  var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)? { get set }
  /// The viewer's size in points: backends that can resize the remote
  /// desktop to fit (VNC ExtendedDesktopSize) do; the default ignores it.
  func requestDesktopSize(width: Int, height: Int)
  /// Whether `requestDesktopSize` does anything: what Dynamic Resolution needs (851-2340).
  var resizesDesktop: Bool { get }
  /// The desktop's size when the session opened: what turning Dynamic Resolution off restores
  /// when the server names no provisioned size.
  var initialDesktopSize: (width: Int, height: Int)? { get }
  /// The measured link rate (851-2331), for choosing 1× or 2× pixels; nil until measured.
  var linkBitsPerSecond: Double? { get }
}

extension ScreenSharingViewingSession {
  public func requestDesktopSize(width: Int, height: Int) {}
  public var resizesDesktop: Bool { false }
  public var initialDesktopSize: (width: Int, height: Int)? { nil }
  public var linkBitsPerSecond: Double? { nil }

  public var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)? {
    get { nil }
    set {}
  }
}
