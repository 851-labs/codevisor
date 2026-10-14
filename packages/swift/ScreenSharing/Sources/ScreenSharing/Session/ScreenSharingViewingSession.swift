import Foundation

public struct ScreenSharingCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let control = ScreenSharingCapabilities(rawValue: 1 << 0)
  public static let clipboard = ScreenSharingCapabilities(rawValue: 1 << 1)
  public static let statistics = ScreenSharingCapabilities(rawValue: 1 << 2)
  public static let systemKeys = ScreenSharingCapabilities(rawValue: 1 << 3)
}

public enum ScreenSharingCursorUpdate: Sendable, Equatable {
  case shape(RFBCursorShape)
  case position(RFBPoint)
  case sizedShape(RFBCursorShape, width: Double, height: Double)
  case normalizedPosition(ScreenSharingPointer?)
}

@MainActor
public protocol ScreenSharingViewingSession: AnyObject {
  var capabilities: ScreenSharingCapabilities { get }
  var frames: ScreenSharingFrameMailbox { get }
  var metrics: ScreenSharingMetrics { get }
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { get }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { get }
  var failure: String? { get }
  var onConnectionChanged: ((String) -> Void)? { get set }
  func statistics() async -> [String: String]
  func close()
  var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)? { get set }
  func requestDesktopSize(width: Int, height: Int)
  func resetDesktopSize()
  var resizesDesktop: Bool { get }
  var onResizeSupportChanged: ((Bool) -> Void)? { get set }
  var initialDesktopSize: (width: Int, height: Int)? { get }
  var linkBitsPerSecond: Double? { get }
  var videoShowsPointer: Bool { get }
  var supportsAudio: Bool { get }
  func setAudioEnabled(_ enabled: Bool)
  func setAudioVolume(_ volume: Float)
  func setDisplayHighDynamicRange(_ supported: Bool)
  var supportsHighDynamicRange: Bool { get }
  var onVideoFormatChanged: ((ScreenSharingDynamicRange, String?) -> Void)? { get set }
  func setClipboardSharing(_ enabled: Bool)
}

extension ScreenSharingViewingSession {
  public func requestDesktopSize(width: Int, height: Int) {}
  public func resetDesktopSize() {}
  public var resizesDesktop: Bool { false }
  public var initialDesktopSize: (width: Int, height: Int)? { nil }
  public var linkBitsPerSecond: Double? { nil }
  public var videoShowsPointer: Bool { true }
  public var supportsAudio: Bool { false }
  public func setAudioEnabled(_ enabled: Bool) {}
  public func setAudioVolume(_ volume: Float) {}
  public func setDisplayHighDynamicRange(_ supported: Bool) {}
  public var supportsHighDynamicRange: Bool { false }
  public func setClipboardSharing(_ enabled: Bool) {}
  public var onVideoFormatChanged: ((ScreenSharingDynamicRange, String?) -> Void)? {
    get { nil }
    set {}
  }

  public var onCursorChanged: ((ScreenSharingCursorUpdate) -> Void)? {
    get { nil }
    set {}
  }

  public var onResizeSupportChanged: ((Bool) -> Void)? {
    get { nil }
    set {}
  }
}
