import CodevisorCore
import CodevisorUI
import SwiftUI

struct AppWindowRoot: ViewModifier {
  let environment: AppEnvironment
  @State private var lightbox = FileLightbox()

  func body(content: Content) -> some View {
    content
      .environment(\.fileLightbox, lightbox)
      .background(FileLightboxWindowOverlay(lightbox: lightbox, environment: environment))
      .onAppear { MenuOrigin.shared.startTracking() }
      .themedRoot()
      .environment(environment)
  }
}

extension View {
  func appWindowRoot(_ environment: AppEnvironment) -> some View {
    modifier(AppWindowRoot(environment: environment))
  }
}
