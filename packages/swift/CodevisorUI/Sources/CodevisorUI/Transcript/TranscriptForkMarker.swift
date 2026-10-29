import SwiftUI

struct TranscriptForkMarker: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "arrow.triangle.branch")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
