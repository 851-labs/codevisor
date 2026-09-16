import SwiftUI

struct FileConflictView: View {
  @Bindable var model: FilePaneModel
  private var document: FileDocumentModel { model.document }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("Review changes").font(.title2.bold())
        Text(
          "The file changed on the machine while you were editing. Your edits are preserved. Choose which version to continue with."
        )
        .foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Text("Your edits").font(.headline)
            Text(document.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Divider()
            Text("On the machine").font(.headline)
            Text(document.conflict?.content ?? "This file is no longer editable text.")
              .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16) { conflictActions }.fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: 16) { conflictActions }
        }
      }.padding(20)
        .frame(minWidth: 300, idealWidth: 700, minHeight: 400, idealHeight: 600)
    }
  }

  @ViewBuilder private var conflictActions: some View {
    Button("Cancel") { model.showsConflict = false }
    Button("Use Machine Version", role: .destructive) {
      document.useDiskVersion()
      model.showsConflict = false
    }
    Button("Keep My Edits") {
      document.keepEdits()
      model.showsConflict = false
    }
    .disabled(document.conflict?.writable != true)
  }
}
