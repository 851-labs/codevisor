import ComposableArchitecture
import SwiftUI

/// The toolbar's Dynamic Resolution switch (851-2340), shared by the app and
/// the rig: on, the remote desktop follows the pane at the Mac's resolution;
/// off, it keeps its own size, scaled to fit. `persist` stores the machine's
/// choice (the reducer doesn't know which machine it is).
public struct ScreenSharingDynamicResolutionToggle: View {
  let store: StoreOf<ScreenSharingViewer>
  let persist: (Bool) -> Void

  public init(store: StoreOf<ScreenSharingViewer>, persist: @escaping (Bool) -> Void) {
    self.store = store
    self.persist = persist
  }

  public var body: some View {
    Toggle(
      isOn: Binding(
        get: { store.dynamicResolution },
        set: { _ in
          store.send(.dynamicResolutionToggled)
          persist(store.dynamicResolution)
        })
    ) {
      Label("Dynamic Resolution", systemImage: "arrow.up.left.and.arrow.down.right")
        .labelStyle(.iconOnly)
    }
    .toggleStyle(.button)
    .accessibilityLabel("Dynamic Resolution")
    .help(
      store.dynamicResolution
        ? "Dynamic Resolution is on: the remote desktop matches this pane at your Mac's resolution"
        : "Dynamic Resolution is off: the remote desktop keeps its own size, scaled to fit")
  }
}
