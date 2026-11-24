import SwiftUI

struct FileViewerContent: View {
  let model: FilePaneModel
  var poster: OSImage?
  @Environment(\.openFileDocument) private var openFile

  private var document: FileDocumentModel { model.document }

  var body: some View {
    if model.mediaKind == .image {
      FileImageViewer(path: model.path, client: model.client, poster: poster)
        .id(model.path)
    } else if model.mediaKind == .video {
      FileVideoPlayer(path: model.path, client: model.client)
        .id(model.path)
    } else if document.isMissing {
      FileMissingView(model: model)
    } else if let snapshot = document.snapshot {
      if snapshot.content == nil {
        FileMediaPreview(path: model.path, client: model.client, size: snapshot.size)
          .id(snapshot.version)
      } else {
        FileTextContent(model: model, openFile: openLocalFile)
      }
    } else if document.isLoading {
      ProgressView("Opening file…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "File unavailable", systemImage: "doc.questionmark", description: Text("Check the connection and try again."))
    }
  }

  private func openLocalFile(_ target: String) -> Bool {
    let rendered = FileDocumentLocation.opensRendered(target)
    if openFile?(target, rendered: rendered) == true { return true }
    guard let path = FileDocumentLocation.resolve(target, relativeTo: model.rootPath) else { return false }

    model.navigate(to: path)
    model.editor.reveal(target, rendered: rendered)
    return true
  }
}

private struct FileTextContent: View {
  let model: FilePaneModel
  let openFile: (String) -> Bool

  private var document: FileDocumentModel { model.document }

  var body: some View {
    ZStack {
      FileSourceEditor(session: model.editor)
        .id(model.path)
        .opacity(model.editor.preview ? 0 : 1)
        .allowsHitTesting(!model.editor.preview)
        .accessibilityHidden(model.editor.preview)
      if model.editor.preview && document.isHTML {
        FileHTMLPreview(
          document: document, rootPath: model.rootPath, client: model.client, openFile: openFile,
          openWebLink: { model.onOpenWebLink?($0) == true })
      } else if model.editor.preview {
        FileMarkdownPreview(document: document, client: model.client, openFile: openFile)
      }
    }
  }
}
