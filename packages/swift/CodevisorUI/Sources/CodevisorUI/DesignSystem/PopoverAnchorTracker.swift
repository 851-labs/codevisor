#if os(macOS)
  import AppKit
  import SwiftUI

  struct PopoverAnchorTracker: NSViewRepresentable {
    let onAnchorScrolled: () -> Void

    func makeNSView(context _: Context) -> PopoverAnchorTrackingView {
      let view = PopoverAnchorTrackingView()
      view.onAnchorScrolled = onAnchorScrolled
      return view
    }

    func updateNSView(_ view: PopoverAnchorTrackingView, context _: Context) {
      view.onAnchorScrolled = onAnchorScrolled
    }

    static func dismantleNSView(_ view: PopoverAnchorTrackingView, coordinator _: ()) {
      view.stopTracking()
    }
  }
#endif
