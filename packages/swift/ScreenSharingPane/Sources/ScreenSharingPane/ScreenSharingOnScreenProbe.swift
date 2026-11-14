#if os(iOS)
  import SwiftUI

  struct ScreenSharingOnScreenProbe: UIViewRepresentable {
    let model: ScreenSharingPaneModel

    @MainActor
    final class Coordinator {
      let id = UUID()
      private(set) var model: ScreenSharingPaneModel

      init(model: ScreenSharingPaneModel) {
        self.model = model
      }

      func follow(_ model: ScreenSharingPaneModel, onScreen: Bool) {
        guard model !== self.model else { return }

        self.model.viewRemoved(id)
        self.model = model
        model.setOnScreen(onScreen, for: id)
      }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> ScreenSharingOnScreenView {
      let view = ScreenSharingOnScreenView()
      let coordinator = context.coordinator
      coordinator.model.setOnScreen(false, for: coordinator.id)
      view.onChange = { coordinator.model.setOnScreen($0, for: coordinator.id) }
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
