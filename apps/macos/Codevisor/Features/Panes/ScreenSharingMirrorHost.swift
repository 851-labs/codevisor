import AppKit
import CodevisorCoreMac
import ScreenSharing
import SwiftUI

struct ScreenSharingMirrorHost: NSViewRepresentable {
  let endpoint: ScreenSharingViewerEndpoint

  func makeNSView(context: Context) -> NSView {
    guard let mirror = endpoint.makeMirror() else { return NSView() }
    mirror.setLetterboxColor(.windowBackgroundColor)
    return mirror
  }

  func updateNSView(_ view: NSView, context: Context) {}

  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    (view as? ScreenSharingMirrorView)?.stop()
  }
}
