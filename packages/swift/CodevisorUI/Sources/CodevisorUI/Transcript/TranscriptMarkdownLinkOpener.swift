import CodevisorCore
import Foundation
import TranscriptKit

/// Opens a Markdown link that points at a workspace file by fetching it
/// in a document tab for Markdown, or through Quick Look for other files. Web links
/// return false so the platform opens them. Shared by the aggregate
/// assistant view, the SwiftUI-hosted transcript rows, and the native settled
/// Markdown host, so every rendering of a reply handles file links the same
/// way.
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
