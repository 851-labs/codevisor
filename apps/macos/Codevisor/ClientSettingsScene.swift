import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct ClientSettingsScene: Scene {
  let runtime: AppRuntime

  var body: some Scene {
    Settings {
      if let environment = runtime.environment {
        SettingsView()
          .themedRoot()
          .environment(environment)
      } else {
        LaunchCover(runtime: runtime) { EmptyView() }
          .task { await runtime.startIfNeeded() }
      }
    }
  }
}
