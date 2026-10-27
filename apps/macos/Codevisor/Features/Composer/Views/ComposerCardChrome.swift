import CodevisorUI
import SwiftUI

struct ComposerCardChrome<S: Shape>: ViewModifier {
  let isEnabled: Bool
  let shape: S
  let namespace: Namespace.ID?

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .padding(ComposerCardStyle.contentPadding)
        .clipShape(shape)
        .composerGlassSurface(shape: shape, id: .composer, in: namespace)
    } else {
      content
    }
  }
}
