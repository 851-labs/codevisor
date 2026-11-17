import SwiftUI

struct SandboxFieldNotes<Field: View>: View {
  var help: String?
  let error: String?
  @ViewBuilder let field: Field

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      field
      if let help {
        Text(help)
          .font(helpFont)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error {
        SandboxErrorLabel(message: error)
          .padding(.top, 2)
      }
    }
  }

  private var helpFont: Font {
    #if os(macOS)
      .subheadline
    #else
      .footnote
    #endif
  }
}
