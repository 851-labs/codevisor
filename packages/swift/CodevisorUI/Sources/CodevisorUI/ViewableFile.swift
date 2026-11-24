import CodevisorCore
import Foundation
import TranscriptKit

public enum ViewableFile: Equatable, Identifiable, Sendable {
  case onMachine(PreviewFile)
  case onDevice(FileDeviceLocation, mimeType: String)

  public init(_ file: PreviewFile) {
    self = .onMachine(file)
  }

  public init(deviceFile url: URL, name: String, mimeType: String) {
    self = .onDevice(FileDeviceLocation(url: url, name: name), mimeType: mimeType)
  }

  public init?(_ attachment: ComposerAttachment) {
    if let url = attachment.fileURL {
      self.init(deviceFile: url, name: attachment.name, mimeType: attachment.mimeType)
    } else if case let .uploaded(reference) = attachment.state {
      self.init(PreviewFile(attachment: reference.attachment))
    } else {
      return nil
    }
  }

  public var id: String { target }

  public var name: String {
    switch self {
    case let .onMachine(file): FileDocumentLocation.typedName(file.name, mimeType: file.mimeType)
    case let .onDevice(location, mimeType): FileDocumentLocation.typedName(location.name, mimeType: mimeType)
    }
  }

  public var mimeType: String {
    switch self {
    case let .onMachine(file): file.mimeType
    case let .onDevice(_, mimeType): mimeType
    }
  }

  public var target: String {
    switch self {
    case let .onMachine(file): FileDocumentLocation.target(for: file)
    case let .onDevice(location, mimeType):
      FileDeviceLocation(url: location.url, name: FileDocumentLocation.typedName(location.name, mimeType: mimeType))
        .target
    }
  }

  public var machineFile: PreviewFile? {
    if case let .onMachine(file) = self { return file }
    return nil
  }

  public var isFolder: Bool { target.hasSuffix("/") }

  public var isPendingCapture: Bool { machineFile?.isPendingCapture == true }

  public var previewKind: FilePreviewKind {
    if machineFile?.kind == .image { return .image }
    return FilePreviewKind(name: name, mimeType: mimeType)
  }
}
