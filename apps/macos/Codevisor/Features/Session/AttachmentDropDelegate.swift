import AppKit
import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentDropDelegate: DropDelegate {
  static let acceptedTypes: [UTType] = [.fileURL, .image]
  private static let droppedImageMimeType = "image/png"

  let attachments: ComposerAttachments?
  @Binding var isTargeted: Bool

  func dropEntered(info: DropInfo) {
    isTargeted = true
  }

  func dropExited(info: DropInfo) {
    isTargeted = false
  }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    guard let attachments else { return false }

    let files = Self.providers(of: .fileURL, in: info)
    files.forEach { attachFile(from: $0, to: attachments) }
    guard files.isEmpty else { return true }

    let images = Self.providers(of: .image, in: info)
    images.forEach { attachImage(from: $0, to: attachments) }
    return !images.isEmpty
  }

  private static func providers(of type: UTType, in info: DropInfo) -> [NSItemProvider] {
    info.itemProviders(for: [type]).filter { $0.hasItemConformingToTypeIdentifier(type.identifier) }
  }

  private func attachFile(from provider: NSItemProvider, to attachments: ComposerAttachments) {
    let id = UUID()
    let placeholder = DroppedFilePlaceholder(name: provider.suggestedName ?? "Dropped file")
    guard
      attachments.beginLoadingAttachment(
        id: id, name: placeholder.name, mimeType: placeholder.mimeType, kind: placeholder.kind)
    else { return }

    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
      let url = Self.fileURL(from: item)
      Task { @MainActor in
        guard let url else {
          attachments.discardLoadingAttachment(id: id)
          return
        }
        attachments.resolveLoadingAttachment(id: id, fromFileURL: url)
      }
    }
  }

  private func attachImage(from provider: NSItemProvider, to attachments: ComposerAttachments) {
    let id = UUID()
    let name = Self.droppedImageName(suggested: provider.suggestedName)
    let mimeType = Self.droppedImageMimeType
    guard attachments.beginLoadingAttachment(id: id, name: name, mimeType: mimeType, kind: .image) else { return }

    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
      let png = data.flatMap(pngData(from:))
      Task { @MainActor in
        guard let png else {
          attachments.discardLoadingAttachment(id: id)
          return
        }
        attachments.resolveLoadingAttachmentReportingFailure(
          id: id, name: name, mimeType: mimeType, kind: .image, data: png)
      }
    }
  }

  private nonisolated static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
    guard let url, url.isFileURL else { return nil }
    return (url as NSURL).filePathURL ?? url
  }

  private static func droppedImageName(suggested: String?) -> String {
    guard let suggested else { return "Dropped image.png" }
    guard (suggested as NSString).pathExtension.isEmpty else { return suggested }
    return "\(suggested).png"
  }
}

private struct DroppedFilePlaceholder {
  let name: String

  var mimeType: String {
    type?.preferredMIMEType ?? "application/octet-stream"
  }

  var kind: Attachment.Kind {
    let isImage = (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
    return isImage ? .image : .file
  }

  private var type: UTType? {
    UTType(filenameExtension: (name as NSString).pathExtension)
  }
}
