import CodevisorCore
import Foundation
import StreamMarkdown
import TranscriptKit

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

  public static func previewFile(_ url: URL) -> PreviewFile? {
    markdownImagePreviewFile(url.relativeString)
  }
}
