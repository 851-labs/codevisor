import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

public struct FileShareLink: View {
  private let item: FileTransferItem

  public init(item: FileTransferItem) {
    self.item = item
  }

  public var body: some View {
    Group {
      switch AttachmentMediaKind(name: item.name, mimeType: item.mimeType, kind: .file) {
      case .image: link(ShareableFile<ImageShareType>(item: item))
      case .video: link(ShareableFile<MovieShareType>(item: item))
      case .pdf: link(ShareableFile<PDFShareType>(item: item))
      case .file: link(ShareableFile<DataShareType>(item: item))
      }
    }
    .labelStyle(.titleAndIcon)
  }

  private func link<T: AttachmentShareType>(_ file: ShareableFile<T>) -> some View {
    ShareLink(item: file, preview: SharePreview(item.name)) {
      Label("Share…", systemImage: "square.and.arrow.up")
    }
  }
}

protocol AttachmentShareType: SendableMetatype {
  static var contentType: UTType { get }
}

enum ImageShareType: AttachmentShareType { static let contentType: UTType = .image }
enum MovieShareType: AttachmentShareType { static let contentType: UTType = .movie }
enum PDFShareType: AttachmentShareType { static let contentType: UTType = .pdf }
enum DataShareType: AttachmentShareType { static let contentType: UTType = .data }

struct ShareableFile<T: AttachmentShareType>: Transferable {
  let item: FileTransferItem

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: T.contentType) { shared in
      let data = try await shared.item.load()
      let directory = CodevisorAppVariant.temporaryURL()
        .appendingPathComponent("Codevisor-Shared-Files", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let name = (shared.item.name as NSString).lastPathComponent
      let url = directory.appendingPathComponent(name.isEmpty ? "Attachment" : name)
      try data.write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }
}
