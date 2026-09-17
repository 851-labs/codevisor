import CodevisorCore
import StreamMarkdown
import SwiftUI

struct FileMarkdownPreview: View {
  let document: FileDocumentModel
  let openFile: (String) -> Bool
  private let imageLoader: MarkdownImageLoader
  @Environment(\.theme) private var theme
  @Environment(\.codeHighlightTheme) private var highlight

  init(document: FileDocumentModel, client: any CodevisorServerClienting, openFile: @escaping (String) -> Bool) {
    self.document = document; self.openFile = openFile
    let path = document.path
    let images = AttachmentImageStore(
      namespace: "file-preview:\(path)",
      fetch: { source in
        switch source {
        case let .attachment(id): return try await client.fileData(id: id)
        case let .serverPath(target):
          guard
            let resolved = MarkdownDocumentPath.resolve(
              target, relativeTo: (path as NSString).deletingLastPathComponent)
          else { throw URLError(.badURL) }
          return try await client.documentData(path: resolved)
        }
      },
      fetchPreview: { source in
        switch source {
        case let .attachment(id): return try await client.filePreview(id: id)
        case let .serverPath(target):
          guard
            let resolved = MarkdownDocumentPath.resolve(
              target, relativeTo: (path as NSString).deletingLastPathComponent)
          else { throw URLError(.badURL) }
          return try await client.filePreview(path: resolved, sessionId: nil)
        }
      }, version: { _ in nil })
    imageLoader = MarkdownImageLoader(id: images.namespace) { await images.markdownImageLoader.image(for: $0) }
  }

  var body: some View {
    ScrollView {
      StreamingMarkdownView(document.text)
        .frame(maxWidth: 860, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity)
    }
    .background(theme.contentBackground)
    .environment(\.markdownImageLoader, imageLoader)
    .environment(\.markdownTheme, makeMarkdownTheme(theme: theme, highlight: highlight.map { ($0.key, $0.json) }))
    .markdownLinkHandler { url in
      guard
        let target = FileDocumentLocation.navigationTarget(
          url.relativeString, relativeTo: (document.path as NSString).deletingLastPathComponent)
      else { return false }
      return openFile(target)
    }
  }
}
