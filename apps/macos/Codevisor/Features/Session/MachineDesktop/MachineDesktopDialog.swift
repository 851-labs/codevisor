import SwiftUI

struct MachineDesktopDialog: View {
  let session: MachineDesktopSession

  var body: some View {
    session.pane.makeView()
      .frame(minWidth: 640, minHeight: 400)
      .toolbar {
        if let store = session.pane.store {
          ScreenSharingToolbar(
            store: store, settings: { session.pane.machineSettings() },
            applySettings: { session.pane.applyMachineSettings($0) })
        }
      }
  }
}
