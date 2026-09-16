import CodevisorCore
import CodevisorUI
import Foundation
import StreamMarkdown
import TranscriptKit

/// What an image drawn inline in a reply does: activation previews it in
/// Quick Look (a text link to the same file opens a document tab instead),
/// and its menu can open that tab or copy the original bytes.
@MainActor
enum TranscriptMarkdownImageOpener {
  static func actions(
    quickLook: QuickLookController?,
    attachmentImages: AttachmentImageStore?,
    openDocument: ((String) -> Bool)?
  ) -> MarkdownImageActions {
    MarkdownImageActions(
      open: { url in
        guard let file = previewFile(url) else { return false }
        quickLook?.present(
          .remote(source: file.source, name: file.name, mimeType: file.mimeType),
          attachmentStore: attachmentImages)
        return true
      },
      openInNewTab: { url in _ = openDocument?(url.relativeString) },
      copy: { url in
        guard let file = previewFile(url), let attachmentImages else { return }
        Task { _ = await AttachmentClipboard.copy(file, using: attachmentImages) }
      })
  }

  /// The workspace file or attachment an image source points at; nil for
  /// web images, which have no local bytes to preview or copy.
  static func previewFile(_ url: URL) -> PreviewFile? {
    markdownAttachmentFile(url.relativeString)
      ?? markdownLocalFilePath(url.relativeString).map { PreviewFile(serverPath: $0) }
  }
}
