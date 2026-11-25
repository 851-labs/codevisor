import SwiftUI

public struct FileLightboxStage: View {
  private let lightbox: FileLightbox

  public init(lightbox: FileLightbox) {
    self.lightbox = lightbox
  }

  public var body: some View {
    #if os(iOS)
      TabView(selection: selection) {
        ForEach(lightbox.files) { file in
          FileLightboxPage(lightbox: lightbox, file: file).tag(file.id)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
    #else
      if let file = lightbox.current {
        FileLightboxPage(lightbox: lightbox, file: file).id(file.id)
      }
    #endif
  }

  private var selection: Binding<String> {
    Binding(
      get: { lightbox.current?.id ?? "" },
      set: { id in
        guard let file = lightbox.files.first(where: { $0.id == id }) else { return }
        lightbox.show(file)
      })
  }
}

private struct FileLightboxPage: View {
  let lightbox: FileLightbox
  let file: ViewableFile
  @Environment(\.scenePhase) private var scenePhase

  private static let retryDelay: Duration = .milliseconds(200)

  var body: some View {
    if let page = lightbox.page(for: file) {
      content(for: page)
        .task(id: page.path) { await load(page) }
    } else {
      ContentUnavailableView(
        "File unavailable", systemImage: "doc.questionmark", description: Text("This file could not be found."))
    }
  }

  @ViewBuilder
  private func content(for page: FilePaneModel) -> some View {
    if let error = page.document.error, page.document.snapshot == nil {
      ContentUnavailableView {
        Label("File unavailable", systemImage: "doc.questionmark")
      } description: {
        Text(error)
      } actions: {
        Button("Try Again") { Task { await page.document.retry() } }
      }
    } else if page.mediaKind == nil, isAwaitingDocument(page) {
      ProgressView("Opening file…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        FileDocumentBanners(model: page)
        FileViewerContent(model: page, poster: lightbox.opener?.poster(file))
      }
    }
  }

  private func load(_ page: FilePaneModel) async {
    guard page.mediaKind == nil else { return }

    await open(page)
    await page.followDisk { scenePhase == .active }
  }

  private func open(_ page: FilePaneModel) async {
    await page.refreshDocument()
    while !Task.isCancelled, isAwaitingDocument(page) {
      try? await Task.sleep(for: Self.retryDelay)
      await page.refreshDocument()
    }
  }

  private func isAwaitingDocument(_ page: FilePaneModel) -> Bool {
    let document = page.document
    return document.snapshot == nil && !document.isMissing && document.error == nil
  }
}
