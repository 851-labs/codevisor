import CodevisorCore
import SwiftUI

struct HarnessUninstallDialog: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  let setting: HarnessFleet.Setting
  @Binding var isPresented: Bool

  func body(content: Content) -> some View {
    content.confirmationDialog("Uninstall \(setting.name)?", isPresented: $isPresented, titleVisibility: .visible) {
      Button("Uninstall", role: .destructive, action: uninstall)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Applies to machines using global settings. Chats and accounts are kept.")
    }
  }

  private func uninstall() {
    var next = setting
    next.installed = false
    next.enabled = false
    HarnessFleet.set(next, in: environment.configSync)
  }
}
