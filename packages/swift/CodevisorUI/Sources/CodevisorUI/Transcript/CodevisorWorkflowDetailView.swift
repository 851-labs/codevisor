import ACPKit
import SwiftUI
import TranscriptKit

/// The expanded body of a gateway workflow: the files it produced
/// (screenshots, recordings) and what it returned, or the error it failed
/// with. Both read as code blocks.
struct CodevisorWorkflowDetailView: View {
  let details: CodevisorWorkflowDetails

  @Environment(\.transcriptAttachmentThumbnail) private var thumbnail

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let failure = details.failure {
        PlainCodeBodyView(output: failure)
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
  /// Thumbnails wrap rather than scroll sideways: a nested scroll view would
  /// take the transcript's vertical scrolling whenever the pointer is over it.
  @ViewBuilder
  private var files: some View {
    if let thumbnail {
      WrappingHStack(spacing: 8, lineSpacing: 8) {
        ForEach(details.files) { file in thumbnail(file) }
      }
    } else {
      ForEach(details.files) { file in
        Label(file.name, systemImage: file.kind == .image ? "photo" : "doc")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
