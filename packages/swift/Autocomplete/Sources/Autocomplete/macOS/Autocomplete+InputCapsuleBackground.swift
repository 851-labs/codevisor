#if canImport(AppKit)
  import SwiftUI

  extension Autocomplete {
    struct InputCapsuleBackground: View {
      @Environment(\.colorSchemeContrast) private var contrast

      private var increasesContrast: Bool { contrast == .increased }

      var body: some View {
        if increasesContrast {
          capsule.fill(Color(nsColor: .controlBackgroundColor))
            .overlay(capsule.strokeBorder(.primary, lineWidth: 1))
        } else {
          capsule.fill(.fill.secondary)
            .overlay(capsule.strokeBorder(.separator, lineWidth: 0.5))
        }
      }

      private var capsule: Capsule { Capsule(style: .continuous) }
    }
  }
#endif
