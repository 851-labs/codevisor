import CodevisorCore
import Foundation
import StreamMarkdown
import TranscriptKit

@MainActor
public enum TranscriptMarkdownImageOpener {
  public static func actions(
    quickLook: QuickLookController?,
    attachmentImages: AttachmentImageStore?,
    openDocument: OpenFileDocumentAction?,
    quoteActions: TranscriptQuoteActions? = nil
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
      },
      addToChat: addToChat(quoteActions))
  }

  private static func addToChat(_ actions: TranscriptQuoteActions?) -> (@MainActor (URL) -> Void)? {
    guard let actions else { return nil }
    return { url in actions.addImage(at: url) }
  }

  public static func previewFile(_ url: URL) -> PreviewFile? {
    markdownImagePreviewFile(url.relativeString)
  }
}
