import SwiftUI

@MainActor
final class BotMascotPointer {
  #if os(macOS)
    weak var view: NSView?
  #endif

  var viewSide: CGFloat? {
    #if os(macOS)
      view?.bounds.width
    #else
      nil
    #endif
  }

  func location() -> CGPoint? {
    #if os(macOS)
      guard let view, let window = view.window, window.isVisible else { return nil }

      let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      return CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
    #else
      nil
    #endif
  }
}

#if os(macOS)
  struct BotMascotPointerProbe: NSViewRepresentable {
    let pointer: BotMascotPointer

    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      pointer.view = view
      return view
    }

    func updateNSView(_ view: NSView, context: Context) {
      pointer.view = view
    }
  }
#else
  struct BotMascotPointerProbe: View {
    let pointer: BotMascotPointer

    var body: some View {
      Color.clear
    }
  }
#endif
