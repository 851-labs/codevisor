import CodevisorCore
import CodevisorUI
import QuickLook
import SwiftUI

struct AppWindowRoot: ViewModifier {
  let environment: AppEnvironment
  @State private var quickLook = QuickLookController.withAlerts()

  func body(content: Content) -> some View {
    content
      .environment(\.quickLook, quickLook)
      .quickLookPreview(
        Binding(
          get: { quickLook.previewURL },
          set: { quickLook.updatePreviewURL($0) }
        )
      )
      .themedRoot()
      .environment(environment)
  }
}

extension View {
  func appWindowRoot(_ environment: AppEnvironment) -> some View {
    modifier(AppWindowRoot(environment: environment))
  }
}
