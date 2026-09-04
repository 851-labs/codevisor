import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

@MainActor
final class MarkdownDocumentPane: Pane {
  let id: UUID
  let kind: PaneKind = .document
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var onFocus: (() -> Void)?
  private let document: MarkdownDocumentModel

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    self.id = descriptor.id
    self.document = MarkdownDocumentModel(
      path: descriptor.documentPath ?? "",
      sessionId: context.sessionId,
      client: context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
    )
  }

  func makeView() -> AnyView {
    AnyView(
      MarkdownDocumentPaneContent(document: document)
    )
  }

  func focus() { onFocus?() }
  func visibilityChanged(_ visible: Bool) {}
  func willDelete() async { document.cancelLoading() }
  func detach() { document.cancelLoading() }
}

private struct MarkdownDocumentPaneContent: View {
  let document: MarkdownDocumentModel
  @Environment(\.openMarkdownDocument) private var openDocument
  @Environment(\.quickLook) private var quickLook
  @Environment(\.attachmentImages) private var attachmentImages

  var body: some View {
    MarkdownDocumentView(document: document) { url in
      guard
        let target = MarkdownDocumentPath.resolve(
          url.relativeString, relativeTo: (document.path as NSString).deletingLastPathComponent
        )
      else { return false }
      if MarkdownDocumentPath.isMarkdown(target), let openDocument {
        return openDocument(target)
      }
      // Quick Look uses the server path too; never open a remote machine's
      // absolute path on the client filesystem.
      let file = PreviewFile(serverPath: target)
      quickLook?.present(
        .remote(source: file.source, name: file.name, mimeType: file.mimeType),
        attachmentStore: attachmentImages
      )
      return true
    }
  }
}
