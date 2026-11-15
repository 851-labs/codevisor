import AppKit
import CodevisorCoreMac
import SwiftUI

struct ScreenSharingNativeView: NSViewRepresentable {
  let pane: ScreenSharingPane
  var letterbox: NSColor = .windowBackgroundColor
  var onClick: (() -> Void)?

  func makeNSView(context: Context) -> ScreenSharingClickView { ScreenSharingClickView() }

  func updateNSView(_ container: ScreenSharingClickView, context: Context) {
    container.label = "Control \(pane.connectionName) here"
    container.onClick = onClick.map { takeControl in
      { [weak container] in
        takeControl()
        container?.window?.makeFirstResponder(container?.subviews.first)
      }
    }
    guard let video = pane.videoView() else { return }

    if video.superview !== container {
      container.subviews.forEach { $0.removeFromSuperview() }
      video.removeFromSuperview()
      video.frame = container.bounds
      video.autoresizingMask = [.width, .height]
      container.addSubview(video)
    }
    pane.letterbox(letterbox)
  }

  static func dismantleNSView(_ container: ScreenSharingClickView, coordinator: ()) {
    container.subviews.forEach { $0.removeFromSuperview() }
  }
}
