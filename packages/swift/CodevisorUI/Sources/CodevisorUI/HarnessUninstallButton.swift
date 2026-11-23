import SwiftUI

struct HarnessUninstallButton: View {
  let harnessName: String
  let isAvailable: Bool
  let action: () -> Void

  var body: some View {
    ConfirmingDestructiveButton("Uninstall…", action: action)
      .disabled(!isAvailable)
      .help(help)
  }

  private var help: String {
    if isAvailable { return "Uninstall \(harnessName) from the machines where Codevisor installed it" }
    return "Codevisor didn’t install \(harnessName) on any of your machines. Turn it off instead."
  }
}
