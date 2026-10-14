#if os(macOS)
  import AppKit

  @MainActor
  public protocol ScreenSharingViewerSurface: AnyObject {
    var view: NSView { get }
    var onPresented: (() -> Void)? { get set }
    var onFocusChanged: ((Bool) -> Void)? { get set }
    var onInput: ((ScreenSharingInputEvent) -> Void)? { get set }
    var onInputReleased: (() -> Void)? { get set }
    var onKeyboardReturned: (() -> Void)? { get set }
    var inputFailureMessage: String? { get }
    var capturesSystemShortcuts: Bool { get }
    var dropsInjectedInput: Bool { get set }
    func beginInput() -> Bool
    func endInput()
    func stop()
    func setLetterboxColor(_ color: NSColor)
    func showRemoteCursor(_ update: ScreenSharingCursorUpdate)
    func setVideoShowsPointer(_ shows: Bool)
    var onSizeChanged: ((CGSize, CGFloat) -> Void)? { get set }
    var onScreenHighDynamicRangeChanged: ((Bool) -> Void)? { get set }
  }

  extension ScreenSharingViewerSurface {
    public var onSizeChanged: ((CGSize, CGFloat) -> Void)? {
      get { nil }
      set {}
    }
    public var onScreenHighDynamicRangeChanged: ((Bool) -> Void)? {
      get { nil }
      set {}
    }
    public func showRemoteCursor(_ update: ScreenSharingCursorUpdate) {}
    public func setVideoShowsPointer(_ shows: Bool) {}
  }

  extension ScreenSharingViewerSurface {
    public func setLetterboxColor(_ color: NSColor) {}
  }
#endif
