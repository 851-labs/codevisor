import CodevisorCore
import Foundation
import StreamMarkdown
import TranscriptKit

/// What an image drawn inline in a reply does: activation previews it in
/// Quick Look (a text link to the same file opens a document tab instead),
/// and its menu can open that tab or copy the original bytes.
@MainActor
public enum TranscriptMarkdownImageOpener {
  public static func actions(
    quickLook: QuickLookController?,
    attachmentImages: AttachmentImageStore?,
    openDocument: OpenFileDocumentAction?
  ) -> MarkdownImageActions {
    MarkdownImageActions(
      open: { url in
        guard let file = previewFile(url) else { return nil }
        guard let quickLook else { return Task {} }
        return quickLook.present(QuickLookItem(file), attachmentStore: attachmentImages)
      },
      openInNewTab: { url in _ = openDocument?(url.relativeString) },
      copy: { url in
        guard let file = previewFile(url), let attachmentImages else { return }
        Task { _ = await AttachmentClipboard.copy(file, using: attachmentImages) }
      })
  }

  /// The workspace file or attachment an image source points at; nil for
  /// web images, which have no local bytes to preview or copy.
  public static func previewFile(_ url: URL) -> PreviewFile? {
    markdownImagePreviewFile(url.relativeString)
  }
}
