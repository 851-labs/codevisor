import CodevisorUI
import SwiftUI

struct SandboxCodevisorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var runtime = AppRuntime.shared

  var body: some Scene {
    MainWindowScene(runtime: runtime)
      .defaultLaunchBehavior(.suppressed)
      .restorationBehavior(.disabled)
    ClientSettingsScene(runtime: runtime)
    MenuBarExtra {
      SandboxMenuBarMenu()
    } label: {
      CodevisorSymbol.codevisorMark.image
        .accessibilityLabel("Codevisor")
    }
  }
}
