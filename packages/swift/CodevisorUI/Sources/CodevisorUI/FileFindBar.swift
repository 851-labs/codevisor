import SwiftUI

struct FileFindBar: View {
  @Bindable var model: FilePaneModel
  private var document: FileDocumentModel { model.document }
  @FocusState private var findFocused: Bool

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Button {
          model.showsReplacement.toggle()
        } label: {
          Image(systemName: model.showsReplacement ? "chevron.down" : "chevron.right")
        }
        .accessibilityLabel("Show Replace")
        TextField("Find in file", text: $model.findText)
          .accessibilityLabel("Find in file")
          .focused($findFocused)
          .task {
            model.editor.resignFocus()
            await Task.yield()
            guard !Task.isCancelled else { return }
            findFocused = true
          }
          .onSubmit { model.findNext() }
        Button("Next") { model.findNext() }
        Button {
          model.showsFind = false
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close Find")
      }
      if model.showsReplacement {
        HStack {
          TextField("Replace with", text: $model.replacement).accessibilityLabel("Replace with")
          Button("Replace") { model.replaceSelection() }
            .disabled(!document.isEditable || model.findText.isEmpty)
        }
      }
    }
    .textFieldStyle(.roundedBorder).padding(10)
    .background(.bar)
  }

}
