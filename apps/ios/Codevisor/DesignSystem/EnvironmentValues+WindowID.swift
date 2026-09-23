import SwiftUI

extension EnvironmentValues {
  /// The window (scene) this view lives in. iPad can show the app in
  /// several windows at once; caches of UIKit views key on it so two
  /// windows never contend for one view, which can only have one parent.
  @Entry var windowID = WindowIdentity.fallback
}

enum WindowIdentity {
  /// Views outside a `WindowIdentityRoot` share one identity.
  static let fallback = UUID()
}

/// Gives each window its own identity for the lifetime of its scene.
struct WindowIdentityRoot<Content: View>: View {
  @State private var id = UUID()
  @ViewBuilder var content: Content

  var body: some View {
    content.environment(\.windowID, id)
  }
}
