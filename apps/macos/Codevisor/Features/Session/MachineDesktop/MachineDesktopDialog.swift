import SwiftUI

struct MachineDesktopDialog: View {
  let session: MachineDesktopSession

  var body: some View {
    session.window.makeView()
      .frame(minWidth: 640, minHeight: 400)
      .toolbar {
        if let store = session.window.store {
          ScreenSharingToolbar(
            store: store, settings: { session.window.machineSettings() },
            applySettings: { session.window.applyMachineSettings($0) })
        }
      }
  }
}
