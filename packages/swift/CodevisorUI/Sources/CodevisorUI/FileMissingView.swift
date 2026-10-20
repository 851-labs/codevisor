import SwiftUI

struct FileMissingView: View {
  let model: FilePaneModel

  private var document: FileDocumentModel { model.document }

  var body: some View {
    ContentUnavailableView {
      Text("File Not Found").font(.title2.bold())
    } description: {
      Text(model.displayPath)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    } actions: {
      if document.isDirty {
        Button("Restore File") { Task { await document.recreate() } }
          .buttonStyle(.borderedProminent)
          .disabled(document.isSaving)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
