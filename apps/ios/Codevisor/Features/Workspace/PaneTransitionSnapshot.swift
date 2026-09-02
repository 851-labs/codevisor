import UIKit

/// Safari-style tab previews: the visible pane is snapshotted (with the app's
/// own navigation chrome cropped off) when the grid opens. Real previews are
/// retained in memory and persisted as stale-while-revalidate images, so a
/// relaunch can paint the grid before any live transcript reconnects.
struct PaneTransitionSnapshot {
  let image: UIImage?
  /// The pane-owned content rectangle in window coordinates. Navigation
  /// chrome and the chat composer deliberately live outside it.
  let contentFrame: CGRect
  /// Render-server-backed views are cheap to create and retain their pixels
  /// without synchronously rasterizing the whole window. They exist only
  /// for the transition that captured them; the image remains the durable
  /// card-preview cache.
  let transitionView: UIView?
  let backdropView: UIView?
}
