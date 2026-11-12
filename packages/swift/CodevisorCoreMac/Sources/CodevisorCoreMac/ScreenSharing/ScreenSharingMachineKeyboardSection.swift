import SwiftUI

struct ScreenSharingMachineKeyboardSection: View {
  @Binding var keyboard: ScreenSharingMachineSettings.Keyboard
  let machineName: String

  var body: some View {
    Section {
      Toggle("Take screenshots on this Mac", isOn: $keyboard.screenshotsStayLocal)
    } header: {
      Text("Keyboard")
    } footer: {
      Text("Screenshot shortcuts like ⇧⌘4 work on this Mac instead of going to \(machineName).")
    }
  }
}
