import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

extension ComposerBar {
  static let droppableTypes: [UTType] = [.fileURL, .image, .data]

  func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
    guard !controller.isSubmitting, remainingAttachmentSlots > 0 else { return false }
    let accepted = providers.filter { Self.canAttachDrop($0) }.prefix(remainingAttachmentSlots)
    guard !accepted.isEmpty else { return false }
    ComposerPasteProviderLoader.logInvocation(route: "drop", providers: Array(accepted))
    for provider in accepted {
      if ComposerPasteProviderLoader.canLoadAttachment(from: provider) {
        ComposerPasteProviderLoader.startLoading(from: provider, onEvent: handlePasteAttachmentEvent)
      } else {
        startLoadingDroppedFile(provider)
      }
    }
    return true
  }

  private static func canAttachDrop(_ provider: NSItemProvider) -> Bool {
    ComposerPasteProviderLoader.canLoadAttachment(from: provider) || fileContentType(of: provider) != nil
  }

  private static func fileContentType(of provider: NSItemProvider) -> UTType? {
    provider.registeredContentTypes.first { $0.conforms(to: .data) }
  }

  private func startLoadingDroppedFile(_ provider: NSItemProvider) {
    guard let type = Self.fileContentType(of: provider) else { return }
    let id = UUID()
    let name =
      provider.suggestedName.map { name in
        (name as NSString).pathExtension.isEmpty
          ? type.preferredFilenameExtension.map { "\(name).\($0)" } ?? name : name
      } ?? "Dropped file"
    let kind: Attachment.Kind = type.conforms(to: .image) ? .image : .file
    handlePasteAttachmentEvent(
      .began(id: id, name: name, mimeType: type.preferredMIMEType ?? "application/octet-stream", kind: kind))
    _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
      let copied = url.flatMap { Self.copyDroppedFile($0, named: name) }
      Task { @MainActor in
        if let copied {
          handlePasteAttachmentEvent(.resolved(id: id, attachment: .fileURL(copied)))
        } else {
          handlePasteAttachmentEvent(
            .failed(id: id, message: error?.localizedDescription ?? "Couldn't read the dropped file.", kind: kind))
        }
      }
    }
  }

  private nonisolated static func copyDroppedFile(_ url: URL, named name: String) -> URL? {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerDrops", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: url, to: destination)
      return destination
    } catch {
      return nil
    }
  }
}
