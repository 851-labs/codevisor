import CodevisorUI
import SwiftUI

struct MenuBarCodevisorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var runtime = AppRuntime.shared

  var body: some Scene {
    MainWindowScene(runtime: runtime)
      .defaultLaunchBehavior(.suppressed)
      .restorationBehavior(.disabled)
    ClientSettingsScene(runtime: runtime)
    MenuBarExtra {
      MenuBarMenu()
    } label: {
      MenuBarIcon()
    }
  }
}
