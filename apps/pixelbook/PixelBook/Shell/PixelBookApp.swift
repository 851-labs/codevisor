import SwiftUI

@main
struct PixelBookApp: App {
  var body: some Scene {
    WindowGroup("PixelBook") {
      PixelBookRootView()
    }
    .defaultSize(width: 1040, height: 720)
    .commands { PixelBookCommands() }
  }
}
