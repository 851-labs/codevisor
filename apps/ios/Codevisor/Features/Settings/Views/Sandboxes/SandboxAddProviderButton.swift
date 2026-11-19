import SwiftUI

struct SandboxAddProviderButton: View {
  let isPrimary: Bool
  let action: () -> Void

  var body: some View {
    if isPrimary {
      button
        .buttonStyle(.glassProminent)
        .tint(.accentColor)
    } else {
      button
    }
  }

  private var button: some View {
    Button("Add Provider", systemImage: "plus", action: action)
      .labelStyle(.iconOnly)
  }
}
