import Foundation
import UniformTypeIdentifiers

/// A file staged in the composer: bytes held locally for instant thumbnails,
/// uploaded eagerly so send only has to collect the server refs.
public struct ComposerAttachment: Identifiable, Equatable {
    public enum State: Equatable {
        case uploading
        case uploaded(ServerAttachmentRef)
        case failed(String)
    }

    public let id: UUID
    public var name: String
    public var mimeType: String
    public var kind: Attachment.Kind
    public var localData: Data
    public var state: State

    public var isImage: Bool { kind == .image }

    public var isPDF: Bool {
        mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
    }

    public var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

    /// Images, PDFs, and videos render as visual previews; everything else is a chip.
    public var hasVisualPreview: Bool { isImage || isPDF || isVideo }
}

/// Whether an attachment is a video, by MIME type first and filename
/// extension (via UTType) as fallback. Shared by the composer model and the
/// attachment views.
public func attachmentIsVideo(name: String, mimeType: String) -> Bool {
    if mimeType.lowercased().hasPrefix("video/") { return true }
    let pathExtension = (name as NSString).pathExtension
    guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
        return false
    }
    return type.conforms(to: .movie)
}
