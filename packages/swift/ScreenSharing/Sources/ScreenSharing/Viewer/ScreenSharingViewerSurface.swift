#if os(macOS)
  import AppKit
  import ScreenSharing

  /// The AppKit half of a viewer endpoint: the view the pane mounts, its input
  /// capture, and the signal that a frame reached the screen. The product
  /// surface is `ScreenSharingVideoSurface`; tests supply a controlled one.
  @MainActor
  public protocol ScreenSharingViewerSurface: AnyObject {
    var view: NSView { get }
    /// Fired for every presentation; the endpoint reports only the first.
    var onPresented: (() -> Void)? { get set }
    var onFocusChanged: ((Bool) -> Void)? { get set }
    var onInput: ((ScreenSharingInputEvent) -> Void)? { get set }
    /// The surface lost the ability to capture input (event tap interrupted, focus refused).
    var onInputReleased: (() -> Void)? { get set }
    var inputFailureMessage: String? { get }
    func beginInput() -> Bool
    func endInput()
    func stop()
    /// The fill around the remote display (letterbox bars, and everything
    /// before the first frame). Surfaces that don't paint one ignore it.
    func setLetterboxColor(_ color: NSColor)
    /// The remote pointer: its shape (the local cursor while controlling) and
    /// the host's moves (drawn over the video while viewing).
    func showRemoteCursor(_ update: ScreenSharingCursorUpdate)
    /// The surface's size in points and its window's backing scale, whenever
    /// either changes (for a remote desktop that follows it).
    var onSizeChanged: ((CGSize, CGFloat) -> Void)? { get set }
  }

  extension ScreenSharingViewerSurface {
    public var onSizeChanged: ((CGSize, CGFloat) -> Void)? {
      get { nil }
      set {}
    }
    public func showRemoteCursor(_ update: ScreenSharingCursorUpdate) {}
  }

  extension ScreenSharingViewerSurface {
    public func setLetterboxColor(_ color: NSColor) {}
  }
#endif
