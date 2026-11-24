import CodevisorUI
import SwiftUI

extension View {
  func fileLightboxSheet(_ lightbox: FileLightbox) -> some View {
    modifier(FileLightboxSheetPresenter(lightbox: lightbox))
  }
}

private struct FileLightboxSheetPresenter: ViewModifier {
  let lightbox: FileLightbox

  func body(content: Content) -> some View {
    content.sheet(isPresented: isPresented) {
      FileLightboxSheet(lightbox: lightbox)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { lightbox.isPresented },
      set: { presented in
        if !presented { lightbox.dismiss() }
      })
  }
}

private struct FileLightboxSheet: View {
  let lightbox: FileLightbox

  var body: some View {
    NavigationStack {
      FileLightboxStage(lightbox: lightbox)
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark", action: lightbox.dismiss)
          }
          ToolbarItemGroup(placement: .primaryAction) {
            if let page { FilePanePreviewToggle(model: page) }
            if let file = lightbox.current, let opener = lightbox.opener {
              FileLightboxSheetActions(opener: opener, file: file)
            }
          }
        }
    }
  }

  private var page: FilePaneModel? {
    lightbox.current.flatMap(lightbox.page(for:))
  }

  private var title: String {
    page?.title ?? lightbox.current?.name ?? ""
  }
}

private struct FileLightboxSheetActions: View {
  let opener: FileOpener
  let file: ViewableFile

  var body: some View {
    Menu("More", systemImage: "ellipsis") {
      FileMenuContent(opener.menu(for: file, omitting: .preview))
    }
  }
}
