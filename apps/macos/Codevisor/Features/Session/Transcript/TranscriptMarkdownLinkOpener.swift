import CodevisorUI
import Foundation
import TranscriptKit

/// Opens a Markdown link that points at a workspace file by fetching it
/// through the attachment store and presenting it in Quick Look. Web links
/// return false so the platform opens them. Shared by the aggregate
/// assistant view, the SwiftUI-hosted transcript rows, and the native settled
/// Markdown host, so every rendering of a reply handles file links the same
/// way.
@MainActor
enum TranscriptMarkdownLinkOpener {
  static func open(
    _ url: URL,
    quickLook: QuickLookController?,
    attachmentImages: AttachmentImageStore?
  ) -> Bool {
    guard let path = markdownLocalFilePath(url.relativeString) else { return false }
    let file = PreviewFile(serverPath: path)
    quickLook?.present(
      .remote(source: file.source, name: file.name, mimeType: file.mimeType),
      attachmentStore: attachmentImages
    )
    return true
  }
}
