import SwiftUI

struct FileDetailsView: View {
  @Bindable var model: FilePaneModel
  private var document: FileDocumentModel { model.document }

  var body: some View {
    NavigationStack {
      Form {
        LabeledContent("Name", value: document.name)
        LabeledContent("Location") { Text(model.path).textSelection(.enabled) }
        LabeledContent(
          "Size",
          value: ByteCountFormatter.string(fromByteCount: Int64(document.snapshot?.size ?? 0), countStyle: .file))
        if document.snapshot?.content != nil {
          LabeledContent("Encoding", value: "UTF-8")
          LabeledContent("Selection", value: "Line \(model.editor.cursorLine), column \(model.editor.cursorColumn)")
        }
        LabeledContent(
          "Status", value: document.isDirty ? "Unsaved changes" : document.isEditable ? "Saved" : "Read-only")
        if let reason = document.snapshot?.reason { Text(reason).foregroundStyle(.secondary) }
      }
      .formStyle(.grouped)
      .navigationTitle("File Info")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showsDetails = false } } }
    }
    #if canImport(AppKit)
      .frame(width: 480, height: 360)
    #endif
  }

}
