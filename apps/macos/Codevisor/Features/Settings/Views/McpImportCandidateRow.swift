import CodevisorCore
import SwiftUI
import CodevisorUI

struct McpImportCandidateRow: View {
  let candidate: ServerNativeMcpImportCandidate
  let foundIn: String
  let isImporting: Bool
  let importDisabled: Bool
  let onImport: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: candidate.transport == "http" ? "globe" : "terminal")
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(candidate.name).foregroundStyle(.primary)
        Text("Found in \(foundIn) · \(candidate.identity)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if isImporting {
        ProgressView().controlSize(.small)
      } else {
        Button("Import") {
          onImport()
        }
        .controlSize(.small)
        .disabled(importDisabled)
        .help("Add to Codevisor's plugins")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(candidate.name), found in \(foundIn)")
  }
}
