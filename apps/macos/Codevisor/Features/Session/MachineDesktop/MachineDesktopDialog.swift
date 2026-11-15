import SwiftUI

struct MachineDesktopDialog: View {
  let pane: ScreenSharingPane

  var body: some View {
    pane.makeView()
      .frame(minWidth: 640, minHeight: 400)
      .toolbar {
        if let store = pane.store {
          ScreenSharingToolbar(
            store: store, settings: { pane.machineSettings() }, applySettings: { pane.applyMachineSettings($0) })
        }
      }
  }
}
