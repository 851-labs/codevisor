import Foundation
import UniformTypeIdentifiers

extension SessionController {
  public func addTranscriptImage(_ file: PreviewFile) {
    let name = Self.imageName(file.name, mimeType: file.mimeType)
    let source = file.source
    attachImage(named: name, mimeType: file.mimeType) { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.fileData(for: source)
    }
  }

  public func addRemoteImage(_ url: URL) {
    let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
    let name = Self.imageName(url.deletingPathExtension().lastPathComponent, mimeType: mimeType)
    attachImage(named: name, mimeType: mimeType) {
      try await URLSession.shared.data(from: url).0
    }
  }

  private func attachImage(
    named name: String, mimeType: String, data: @escaping @Sendable () async throws -> Data
  ) {
    transcriptPickSignal &+= 1
    let attached = attachments.attachLoading(name: name, mimeType: mimeType, kind: .image) { id, files in
      let fileURL = try files.stage(data: try await data(), id: id, name: name)
      return LoadedAttachmentFile(fileURL: fileURL, name: name, mimeType: mimeType, kind: .image)
    }
    if attached == nil {
      status = .failed("A message can carry at most \(ComposerAttachments.maxAttachments) attachments.")
    }
  }

  private static func imageName(_ name: String, mimeType: String) -> String {
    let base = name.isEmpty ? "Image" : name
    guard (base as NSString).pathExtension.isEmpty,
      let pathExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension
    else { return base }
    return "\(base).\(pathExtension)"
  }
}
