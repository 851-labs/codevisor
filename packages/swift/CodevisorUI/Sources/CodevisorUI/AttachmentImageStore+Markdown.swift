import CodevisorCore
import Foundation
import StreamMarkdown

extension AttachmentImageStore {
  public var markdownImageLoader: MarkdownImageLoader {
    imageLoader(resolving: markdownImagePreviewFile, isPending: isPendingMarkdownImage)
  }

  public var documentImageLoader: MarkdownImageLoader {
    imageLoader(resolving: documentImagePreviewFile, isPending: { _ in false })
  }

  private func imageLoader(
    resolving previewFile: @escaping @Sendable (String) -> PreviewFile?,
    isPending: @escaping @Sendable (String) -> Bool
  ) -> MarkdownImageLoader {
    MarkdownImageLoader(id: namespace, isPending: isPending) { [weak self] source in
      guard let self else { return nil }
      if let file = previewFile(source) {
        guard let preview = await image(for: file) else { return nil }
        return MarkdownImage(image: preview.image, id: "\(namespace):\(file.id):\(preview.version)")
      }
      return await MarkdownImageLoader.remote.image(for: source)
    }
  }
}

public func markdownImagePreviewFile(_ source: String) -> PreviewFile? {
  if let file = markdownAttachmentFile(source) { return file }
  guard let url = URL(string: source), url.scheme == "https", url.host == "attachments.codevisor.invalid" else {
    return nil
  }
  let id = String(url.path.dropFirst())
  guard !id.isEmpty, !id.contains("/") else { return nil }
  return PreviewFile(source: .attachment(fileId: id), name: "Image", mimeType: "image/png", kind: .image)
}

public func isPendingMarkdownImage(_ source: String) -> Bool {
  markdownImagePreviewFile(source) == nil && markdownLocalFilePath(source) != nil
}

public func documentImagePreviewFile(_ source: String) -> PreviewFile? {
  markdownImagePreviewFile(source) ?? markdownLocalFilePath(source).map { PreviewFile(serverPath: $0) }
}
