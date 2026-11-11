import SwiftUI

struct SettingsMenuAnchorView: NSViewRepresentable {
  let anchor: SettingsMenuAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
