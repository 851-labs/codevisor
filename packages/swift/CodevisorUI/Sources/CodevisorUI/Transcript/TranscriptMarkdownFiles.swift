import Foundation
import StreamMarkdown
import TranscriptKit

@MainActor
public enum TranscriptMarkdownFiles {
  public static func actions(opener: FileOpener?) -> MarkdownFileActions? {
    guard let opener else { return nil }
    return MarkdownFileActions(
      openImage: { url in
        guard let image = markdownImagePreviewFile(url.relativeString) else { return false }
        opener.open(ViewableFile(image))
        return true
      },
      menu: { url in
        guard let file = file(at: url) else { return [] }
        return opener.menu(for: file).markdownItems(share: opener.transfers.share)
      })
  }

  public static func open(_ url: URL, opener: FileOpener?) -> Bool {
    guard let opener, let file = file(at: url) else { return false }

    opener.open(file)
    return true
  }

  public static func file(at url: URL) -> ViewableFile? {
    let target = url.relativeString
    let file = markdownImagePreviewFile(target) ?? markdownLocalFilePath(target).map { PreviewFile(serverPath: $0) }
    return file.map(ViewableFile.init)
  }
}
