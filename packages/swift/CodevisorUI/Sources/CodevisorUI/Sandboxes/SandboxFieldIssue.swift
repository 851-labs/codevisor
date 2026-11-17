import SwiftUI

struct SandboxFieldIssue<Field: View>: View {
  let message: String?
  @ViewBuilder let field: Field

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      field
      if let message {
        SandboxErrorLabel(message: message)
      }
    }
  }
}
