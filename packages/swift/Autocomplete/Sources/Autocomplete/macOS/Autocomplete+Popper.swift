#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    struct Popper<Content: View>: NSViewRepresentable {
      let controller: PopperController
      let isPresented: Binding<Bool>
      let content: Content

      init(controller: PopperController, isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.isPresented = isPresented
        self.content = content()
      }

      func makeCoordinator() -> PopperController { controller }

      func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        let controller = context.coordinator
        view.onWindowChange = { [weak controller] in controller?.sync() }
        view.onFrameChange = { [weak controller] in controller?.anchorDidMove() }
        return view
      }

      func updateNSView(_ view: AnchorView, context: Context) {
        let isPresented = isPresented
        context.coordinator.update(
          isPresented: isPresented.wrappedValue,
          content: AnyView(content), environment: context.environment, anchor: view,
          onDismiss: { isPresented.wrappedValue = false })
      }

      static func dismantleNSView(_ view: AnchorView, coordinator: PopperController) {
        coordinator.tearDown()
      }

      final class AnchorView: NSView {
        var onWindowChange: () -> Void = {}
        var onFrameChange: () -> Void = {}

        override func viewDidMoveToWindow() {
          super.viewDidMoveToWindow()
          onWindowChange()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
          super.setFrameOrigin(newOrigin)
          onFrameChange()
        }

        override func setFrameSize(_ newSize: NSSize) {
          super.setFrameSize(newSize)
          onFrameChange()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
      }
    }
  }
#endif
