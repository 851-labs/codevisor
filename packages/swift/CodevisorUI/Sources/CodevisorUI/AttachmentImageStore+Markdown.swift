import CodevisorCore
import Foundation
import StreamMarkdown

extension AttachmentImageStore {
  public var markdownImageLoader: MarkdownImageLoader {
    MarkdownImageLoader(id: namespace) { [weak self] source in
      guard let self else { return nil }
      if let file = markdownImagePreviewFile(source) {
        guard let preview = await image(for: file) else { return nil }
        return MarkdownImage(image: preview.image, id: "\(namespace):\(file.id):\(preview.version)")
      }
      return await MarkdownImageLoader.remote.image(for: source)
    }
  }
}

/// Attachment embeds can omit the download-name query used by named links.
/// Resolve their immutable ID directly instead of making an HTTP request to
/// the synthetic attachments origin.
func markdownImagePreviewFile(_ source: String) -> PreviewFile? {
  if let file = markdownAttachmentFile(source) { return file }
  if let url = URL(string: source), url.scheme == "https", url.host == "attachments.codevisor.invalid" {
    let id = String(url.path.dropFirst())
    guard !id.isEmpty, !id.contains("/") else { return nil }
    return PreviewFile(source: .attachment(fileId: id), name: "Image", mimeType: "image/png", kind: .image)
  }
  return markdownLocalFilePath(source).map { PreviewFile(serverPath: $0) }
}
