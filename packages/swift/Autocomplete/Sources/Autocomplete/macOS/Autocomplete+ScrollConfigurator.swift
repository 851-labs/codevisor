#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    /// The only AppKit scroll adaptation: native scroller size and the search
    /// field's accessibility relationship to its results. Content geometry and
    /// bounce behavior belong to the actual ScrollView.
    struct ScrollConfigurator: NSViewRepresentable {
      let usesMiniScroller: Bool
      let onResolve: (NSScrollView) -> Void
      func makeNSView(context: Context) -> ProbeView { ProbeView() }
      func updateNSView(_ view: ProbeView, context: Context) {
        view.configure = { scrollView in
          let size: NSControl.ControlSize = usesMiniScroller ? .mini : .regular
          if scrollView.verticalScroller?.controlSize != size {
            scrollView.verticalScroller?.controlSize = size
            scrollView.tile()
          }
          onResolve(scrollView)
        }
        view.apply()
      }
      static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.configure = nil }

      final class ProbeView: NSView {
        var configure: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
          DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = enclosingScrollView else { return }
            configure?(scrollView)
          }
        }
      }
    }
  }
#endif
