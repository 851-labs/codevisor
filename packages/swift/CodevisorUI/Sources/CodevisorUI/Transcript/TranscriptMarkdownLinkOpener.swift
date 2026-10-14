import CodevisorCore
import Foundation
import TranscriptKit

@MainActor
public enum TranscriptMarkdownLinkOpener {
  public static func open(
    _ url: URL,
    quickLook: QuickLookController?,
    attachmentImages: AttachmentImageStore?,
    openDocument: OpenFileDocumentAction? = nil
  ) -> Bool {
    if openDocument?(url.relativeString) == true { return true }
    guard
      let file = markdownAttachmentFile(url.relativeString)
        ?? markdownLocalFilePath(url.relativeString).map({ PreviewFile(serverPath: $0) })
    else { return false }
    quickLook?.present(QuickLookItem(file), attachmentStore: attachmentImages)
    return true
  }
}
