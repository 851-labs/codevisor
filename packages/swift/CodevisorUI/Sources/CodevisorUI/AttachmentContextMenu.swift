import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

extension View {
  /// The attachment's secondary actions: open as a workspace tab, copy the
  /// original file, or share it. The primary tap stays a preview.
  public func attachmentContextMenu(
    file: PreviewFile, image: OSImage?, openInNewTab: (@MainActor () -> Void)? = nil
  ) -> some View {
    modifier(AttachmentContextMenu(file: file, image: image, openInNewTab: openInNewTab))
  }
}

/// How an attachment's copy and share actions describe it. Images copy as
/// pictures; everything else copies as a file the pasteboard can drop into
/// Finder, Files, or a message.
public enum AttachmentMediaKind: Equatable, Sendable {
  case image
  case video
  case pdf
  case file

  public init(file: PreviewFile) {
    self.init(name: file.name, mimeType: file.mimeType, kind: file.kind)
  }

  public init(name: String, mimeType: String, kind: Attachment.Kind) {
    let lowered = mimeType.lowercased()
    if kind == .image || lowered.hasPrefix("image/") {
      self = .image
    } else if lowered == "application/pdf" || name.lowercased().hasSuffix(".pdf") {
      self = .pdf
    } else if attachmentIsVideo(name: name, mimeType: mimeType) {
      self = .video
    } else {
      self = .file
    }
  }

  public var copyTitle: String {
    switch self {
    case .image: "Copy Image"
    case .video: "Copy Video"
    case .pdf: "Copy PDF"
    case .file: "Copy File"
    }
  }

  public var copyFailureTitle: String {
    switch self {
    case .image: "Unable to Copy Image"
    case .video: "Unable to Copy Video"
    case .pdf: "Unable to Copy PDF"
    case .file: "Unable to Copy File"
    }
  }
}

/// The uniform type a shared or copied attachment is tagged with: the MIME
/// type when it is known, else the filename extension, else plain data.
public func attachmentContentType(name: String, mimeType: String) -> UTType {
  if let type = UTType(mimeType: mimeType), type != .data { return type }
  let pathExtension = (name as NSString).pathExtension
  if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) { return type }
  return .data
}

private struct AttachmentContextMenu: ViewModifier {
  @Environment(\.attachmentImages) private var attachmentImages
  let file: PreviewFile
  let image: OSImage?
  let openInNewTab: (@MainActor () -> Void)?

  @State private var isCopying = false
  @State private var copyFailed = false

  private var kind: AttachmentMediaKind { AttachmentMediaKind(file: file) }

  /// A broken image (no decoded thumbnail) has nothing worth copying; other
  /// files copy their bytes regardless of whether a preview rendered.
  private var offersFileActions: Bool {
    attachmentImages != nil && (kind != .image || image != nil)
  }

  func body(content: Content) -> some View {
    content
      .contextMenu {
        if let openInNewTab {
          Button("Open in New Tab", systemImage: "plus.rectangle.on.rectangle", action: openInNewTab)
        }
        if let attachmentImages, offersFileActions {
          Button(kind.copyTitle, systemImage: "doc.on.doc") {
            copy(using: attachmentImages)
          }
          .disabled(isCopying)

          switch kind {
          case .image:
            shareLink(ShareableAttachment<ImageShareType>(file: file, store: attachmentImages))
          case .video:
            shareLink(ShareableAttachment<MovieShareType>(file: file, store: attachmentImages))
          case .pdf:
            shareLink(ShareableAttachment<PDFShareType>(file: file, store: attachmentImages))
          case .file:
            shareLink(ShareableAttachment<DataShareType>(file: file, store: attachmentImages))
          }
        }
      }
      .alert(kind.copyFailureTitle, isPresented: $copyFailed) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("The file could not be copied. Please try again.")
      }
  }

  @ViewBuilder
  private func shareLink<T: AttachmentShareType>(_ item: ShareableAttachment<T>) -> some View {
    if let image {
      ShareLink(item: item, preview: SharePreview(file.name, image: previewImage(image)))
    } else {
      ShareLink(item: item, preview: SharePreview(file.name))
    }
  }

  private func previewImage(_ image: OSImage) -> Image {
    #if canImport(AppKit)
      Image(nsImage: image)
    #elseif canImport(UIKit)
      Image(uiImage: image)
    #endif
  }

  private func copy(using store: AttachmentImageStore) {
    guard !isCopying else { return }
    isCopying = true
    Task { @MainActor in
      defer { isCopying = false }
      copyFailed = !(await AttachmentClipboard.copy(file, using: store))
    }
  }
}

/// Copies an attachment's ORIGINAL bytes to the pasteboard; on-screen
/// previews are downsampled. Images land as pictures so they paste into
/// editors; videos, PDFs, and other files land as files (plus their typed
/// data) so they paste into Finder, Files, Mail, and Messages.
public enum AttachmentClipboard {
  @MainActor
  public static func copy(_ file: PreviewFile, using store: AttachmentImageStore) async -> Bool {
    guard let data = try? await store.data(for: file.source), !data.isEmpty else { return false }
    switch AttachmentMediaKind(file: file) {
    case .image:
      guard let image = OSImage(data: data) else { return false }
      #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([image])
      #elseif canImport(UIKit)
        UIPasteboard.general.image = image
        return true
      #endif
    case .video, .pdf, .file:
      guard let url = await materializeClipboardFile(data: data, name: file.name) else { return false }
      let type = attachmentContentType(name: file.name, mimeType: file.mimeType)
      #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { return false }
        let dataType = NSPasteboard.PasteboardType(type.identifier)
        pasteboard.addTypes([dataType], owner: nil)
        return pasteboard.setData(data, forType: dataType)
      #elseif canImport(UIKit)
        UIPasteboard.general.setItems([[type.identifier: data, UTType.fileURL.identifier: url]])
        return true
      #endif
    }
  }

  /// Writes the bytes under the attachment's real filename so pasted files
  /// keep their name and extension.
  static func materializeClipboardFile(data: Data, name: String) async -> URL? {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Codevisor-Clipboard", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let lastPathComponent = (name as NSString).lastPathComponent
    let url = directory.appendingPathComponent(lastPathComponent.isEmpty ? "Attachment" : lastPathComponent)
    let written = await Task.detached(priority: .userInitiated) { () -> Bool in
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
      } catch {
        return false
      }
    }.value
    return written ? url : nil
  }
}

// MARK: - Sharing

/// `FileRepresentation` needs its content type at the type level, so each
/// media kind gets a phantom type instead of a runtime switch.
protocol AttachmentShareType {
  static var contentType: UTType { get }
}

enum ImageShareType: AttachmentShareType { static let contentType: UTType = .image }
enum MovieShareType: AttachmentShareType { static let contentType: UTType = .movie }
enum PDFShareType: AttachmentShareType { static let contentType: UTType = .pdf }
enum DataShareType: AttachmentShareType { static let contentType: UTType = .data }

/// Shares the original file through the system share UI, loading it only
/// when requested; the thumbnail is used solely for the share preview.
struct ShareableAttachment<T: AttachmentShareType>: Transferable {
  let file: PreviewFile
  let store: AttachmentImageStore

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: T.contentType) { item in
      let data = try await item.store.data(for: item.file.source)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Codevisor-Shared-Files", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let name = (item.file.name as NSString).lastPathComponent
      let url = directory.appendingPathComponent(name.isEmpty ? "Attachment" : name)
      try data.write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }
}
