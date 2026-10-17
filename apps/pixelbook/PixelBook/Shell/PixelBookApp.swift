import SwiftUI

@main
struct PixelBookApp: App {
  var body: some Scene {
    WindowGroup("PixelBook") {
      PixelBookRootView()
    }
    .defaultSize(width: WindowFrameGuard.defaultSize.width, height: WindowFrameGuard.defaultSize.height)
    .commands { PixelBookCommands() }
  }
}
