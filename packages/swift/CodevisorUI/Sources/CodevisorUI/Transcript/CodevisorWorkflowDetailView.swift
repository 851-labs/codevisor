import ACPKit
import SwiftUI
import TranscriptKit

/// The expanded body of a gateway workflow: the files it produced
/// (screenshots, recordings) and what it returned, or why it failed.
struct CodevisorWorkflowDetailView: View {
  let details: CodevisorWorkflowDetails

  @Environment(\.theme) private var theme
  @Environment(\.transcriptAttachmentThumbnail) private var thumbnail

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let failure = details.failure {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(theme.statusError)
          .textSelection(.enabled)
      }
      if !details.files.isEmpty { files }
      if let result = details.result {
        PlainCodeBodyView(output: result)
      } else if details.failure == nil, details.files.isEmpty {
        PlainCodeBodyView(output: "")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Screenshots and recordings as the platform shows attachments; plain
  /// names where there is no thumbnail view (previews, detached rows).
  @ViewBuilder
  private var files: some View {
    if let thumbnail {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 8) {
          ForEach(details.files) { file in thumbnail(file) }
        }
      }
      .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
    } else {
      ForEach(details.files) { file in
        Label(file.name, systemImage: file.kind == .image ? "photo" : "doc")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
