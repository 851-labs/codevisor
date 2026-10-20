import SwiftUI

struct CodeBlockLanguageTitle: View {
  let language: String?

  var body: some View {
    Text(language?.uppercased() ?? "CODE")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
  }
}
