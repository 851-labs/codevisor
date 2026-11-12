import SwiftUI

struct ScreenSharingMachineKeyboardSection: View {
  @Binding var keyboard: ScreenSharingMachineSettings.Keyboard

  var body: some View {
    Section {
      Toggle("Take screenshots on this Mac", isOn: $keyboard.screenshotsStayLocal)
    } header: {
      Text("Keyboard")
    } footer: {
      Text(ScreenSharingMachineSettings.Keyboard.screenshotsExplanation)
    }
  }
}
