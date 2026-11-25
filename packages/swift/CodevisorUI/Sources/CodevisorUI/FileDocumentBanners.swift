import SwiftUI

struct FileDocumentBanners: View {
  @Bindable var model: FilePaneModel

  private var document: FileDocumentModel { model.document }

  var body: some View {
    VStack(spacing: 0) {
      if document.conflict != nil {
        HStack {
          Label("This file changed elsewhere", systemImage: "exclamationmark.triangle")
            .font(.callout)
          Spacer()
          Button("Review Changes") { model.showsConflict = true }
        }
        .padding(12).background(.orange.opacity(0.12))
      }
      if let error = document.error ?? document.draftError {
        HStack {
          Label(error, systemImage: "exclamationmark.circle").font(.callout)
          Spacer()
          Button("Retry") { Task { await document.retry() } }
        }.padding(12).background(.orange.opacity(0.08))
      }
    }
    .sheet(isPresented: $model.showsConflict) { FileConflictView(model: model) }
  }
}
