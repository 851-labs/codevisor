import CodevisorCore
import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

public enum AttachmentClipboard {
  @MainActor
  public static func copy(_ item: FileTransferItem) async -> Bool {
    guard let data = try? await item.load(), !data.isEmpty else { return false }
    switch AttachmentMediaKind(name: item.name, mimeType: item.mimeType, kind: .file) {
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
      guard let url = await materializeClipboardFile(data: data, name: item.name) else { return false }
      let type = attachmentContentType(name: item.name, mimeType: item.mimeType)
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

  static func materializeClipboardFile(data: Data, name: String) async -> URL? {
    let directory = CodevisorAppVariant.temporaryURL()
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
