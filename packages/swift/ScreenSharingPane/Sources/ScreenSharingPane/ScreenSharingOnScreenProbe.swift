#if os(iOS)
  import SwiftUI

  struct ScreenSharingOnScreenProbe: UIViewRepresentable {
    let model: ScreenSharingPaneModel
    let pane: UUID

    @MainActor
    final class Coordinator {
      let id = UUID()
      let pane: UUID
      private(set) var model: ScreenSharingPaneModel

      init(model: ScreenSharingPaneModel, pane: UUID) {
        self.model = model
        self.pane = pane
      }

      func report(_ onScreen: Bool) {
        model.setOnScreen(onScreen, for: id, showing: pane)
      }

      func follow(_ model: ScreenSharingPaneModel, onScreen: Bool) {
        guard model !== self.model else { return }

        self.model.viewRemoved(id)
        self.model = model
        report(onScreen)
      }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, pane: pane) }

    func makeUIView(context: Context) -> ScreenSharingOnScreenView {
      let view = ScreenSharingOnScreenView()
      let coordinator = context.coordinator
      coordinator.report(false)
      view.onChange = { coordinator.report($0) }
      return view
    }

    func updateUIView(_ view: ScreenSharingOnScreenView, context: Context) {
      context.coordinator.follow(model, onScreen: view.isOnScreen)
    }

    static func dismantleUIView(_ view: ScreenSharingOnScreenView, coordinator: Coordinator) {
      view.retire()
      coordinator.model.viewRemoved(coordinator.id)
    }
  }
#endif
