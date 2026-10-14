import SwiftUI

extension EnvironmentValues {
  @Entry var windowID = WindowIdentity.fallback
}

enum WindowIdentity {
  static let fallback = UUID()
}

struct WindowIdentityRoot<Content: View>: View {
  @State private var id = UUID()
  @ViewBuilder var content: Content

  var body: some View {
    content.environment(\.windowID, id)
  }
}
