import SwiftUI

#if os(macOS)
  import AppKit
#endif

struct ClearsInitialFocus: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content.background(Clearer())
    #else
      content
    #endif
  }
}

#if os(macOS)
  private struct Clearer: NSViewRepresentable {
    func makeNSView(context: Context) -> ClearingView { ClearingView() }

    func updateNSView(_ nsView: ClearingView, context: Context) {}

    final class ClearingView: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        DispatchQueue.main.async { [weak self] in self?.clearFocus() }
      }

      private func clearFocus() {
        guard let window, let responder = window.firstResponder as? NSView else { return }
        guard !(responder is NSText) else { return }

        window.makeFirstResponder(nil)
      }
    }
  }
#endif
