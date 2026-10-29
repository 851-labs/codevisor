import SwiftUI

struct SandboxDeleteSection: View {
  let title: String
  let onDelete: () -> Void

  var body: some View {
    #if os(iOS)
      Section {
        Button(title, role: .destructive, action: onDelete)
      }
    #endif
  }
}
