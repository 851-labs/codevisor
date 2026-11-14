import AppKit
import CodevisorCoreMac
import SwiftUI

struct ScreenSharingNativeView: NSViewRepresentable {
  let endpoint: ScreenSharingViewerEndpoint
  let holdsPicture: () -> Bool

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    guard holdsPicture() else { return }

    let video = endpoint.view
    if video.superview !== container {
      container.subviews.forEach { $0.removeFromSuperview() }
      video.removeFromSuperview()
      video.frame = container.bounds
      video.autoresizingMask = [.width, .height]
      container.addSubview(video)
    }
    endpoint.letterbox(.windowBackgroundColor)
  }

  static func dismantleNSView(_ container: NSView, coordinator: ()) {
    container.subviews.forEach { $0.removeFromSuperview() }
  }
}
