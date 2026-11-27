import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopSetupPane: View {
  let store: StoreOf<MachineDesktopSetup>
  let view: UUID
  let onOpenTerminal: (() -> Void)?

  var body: some View {
    MachineDesktopSetupStatus(store: store, view: view, size: .pane, onOpenTerminal: onOpenTerminal)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
