import SwiftUI

#if os(macOS)
  struct BotMascotRiveCanvas: NSViewRepresentable {
    let stage: BotMascotStage
    let pointer: BotMascotPointer

    func makeNSView(context: Context) -> BotMascotCanvasView {
      let view = BotMascotCanvasView()
      stage.attach(view, pointer: pointer)
      return view
    }

    func updateNSView(_ view: BotMascotCanvasView, context: Context) {}

    static func dismantleNSView(_ view: BotMascotCanvasView, coordinator: Coordinator) {
      coordinator.stage.detach(view)
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(stage: stage)
    }

    final class Coordinator {
      let stage: BotMascotStage

      init(stage: BotMascotStage) {
        self.stage = stage
      }
    }
  }
#else
  struct BotMascotRiveCanvas: UIViewRepresentable {
    let stage: BotMascotStage
    let pointer: BotMascotPointer

    func makeUIView(context: Context) -> BotMascotCanvasView {
      let view = BotMascotCanvasView()
      stage.attach(view, pointer: pointer)
      return view
    }

    func updateUIView(_ view: BotMascotCanvasView, context: Context) {}

    static func dismantleUIView(_ view: BotMascotCanvasView, coordinator: Coordinator) {
      coordinator.stage.detach(view)
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(stage: stage)
    }

    final class Coordinator {
      let stage: BotMascotStage

      init(stage: BotMascotStage) {
        self.stage = stage
      }
    }
  }
#endif
