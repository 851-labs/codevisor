import SwiftUI

/// A storybook for Codevisor's reusable macOS components. Each story is one
/// variant or edge case of a component, rendered with sample data so the
/// component can be exercised without the product app around it.
@main
struct PixelBookApp: App {
  var body: some Scene {
    WindowGroup("PixelBook") {
      PixelBookRootView()
    }
    .defaultSize(width: 1040, height: 720)
  }
}
