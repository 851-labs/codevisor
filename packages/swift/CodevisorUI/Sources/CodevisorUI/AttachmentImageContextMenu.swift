import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

extension View {
  public func attachmentImageContextMenu(file: PreviewFile, image: OSImage?) -> some View {
    modifier(AttachmentImageContextMenu(file: file, image: image))
  }
}

private struct AttachmentImageContextMenu: ViewModifier {
  @Environment(\.attachmentImages) private var attachmentImages
  let file: PreviewFile
  let image: OSImage?

  @State private var isCopying = false
  @State private var copyFailed = false

  func body(content: Content) -> some View {
    content
      .contextMenu {
        if file.kind == .image, let image, let attachmentImages {
          Button("Copy Image", systemImage: "doc.on.doc") {
            copyImage(using: attachmentImages)
          }
          .disabled(isCopying)

          ShareLink(
            item: ShareableAttachmentImage(file: file, store: attachmentImages),
            preview: SharePreview(file.name, image: previewImage(image))
          )
        }
      }
      .alert("Unable to Copy Image", isPresented: $copyFailed) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("The image could not be copied. Please try again.")
      }
  }

  private func previewImage(_ image: OSImage) -> Image {
    #if canImport(AppKit)
      Image(nsImage: image)
    #elseif canImport(UIKit)
      Image(uiImage: image)
    #endif
  }

  private func copyImage(using store: AttachmentImageStore) {
    guard !isCopying else { return }
    isCopying = true
    Task { @MainActor in
      defer { isCopying = false }
      do {
        // The displayed iOS preview is downsampled; copy the original bytes.
        let data = try await store.data(for: file.source)
        guard let image = OSImage(data: data) else {
          copyFailed = true
          return
        }
        #if canImport(AppKit)
          NSPasteboard.general.clearContents()
          copyFailed = !NSPasteboard.general.writeObjects([image])
        #elseif canImport(UIKit)
          UIPasteboard.general.image = image
        #endif
      } catch {
        copyFailed = true
      }
    }
  }
}

/// Share the original file through the system share UI, loading it only when
/// requested. The thumbnail is used solely for the share preview.
private struct ShareableAttachmentImage: Transferable {
  let file: PreviewFile
  let store: AttachmentImageStore

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .image) { item in
      let data = try await item.store.data(for: item.file.source)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Codevisor-Shared-Images", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let name = (item.file.name as NSString).lastPathComponent
      let url = directory.appendingPathComponent(name.isEmpty ? "Image" : name)
      try data.write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }
}
