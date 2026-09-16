import AppKit
import CodevisorScreenSharing

/// The AppKit half of a viewer endpoint: the view the pane mounts, its input
/// capture, and the signal that a frame reached the screen. The product
/// surface is `ScreenSharingVideoSurface`; tests supply a controlled one.
@MainActor
public protocol ScreenSharingViewerSurface: AnyObject {
  var view: NSView { get }
  var fitToWindow: Bool { get set }
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
}
