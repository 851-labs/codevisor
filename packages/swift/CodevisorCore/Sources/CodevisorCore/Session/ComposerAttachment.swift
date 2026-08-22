import Foundation
import UniformTypeIdentifiers

/// A file staged in the composer: bytes held locally for instant thumbnails,
/// uploaded eagerly so send only has to collect the server refs.
public struct ComposerAttachment: Identifiable, Equatable {
    public enum State: Equatable {
        /// The paste/drop provider has been accepted, but its bytes have not
        /// arrived yet. Keeping this distinct from upload state lets the UI
        /// render an optimistic placeholder immediately.
        case loading
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

/// Decodes the data representation used by `public.file-url` pasteboard
/// items. Item providers are not required to coerce this representation into
/// an `NSURL`, so paste consumers should decode the representation directly.
public func decodePasteboardFileURL(_ data: Data) -> URL? {
    // Cross-device Universal Clipboard providers do not always use
    // URL.dataRepresentation. Some publish the same public.file-url payload
    // as a UTF-8 string (occasionally NUL terminated).
    for encoding in [
        String.Encoding.utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
    ] {
        if let value = String(data: data, encoding: encoding),
            let url = pasteboardFileURL(from: value)
        {
            return url
        }
    }

    if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
        return url
    }

    // Older pasteboard producers archive NSURL objects instead of emitting a
    // URL data representation. Restrict decoding to NSURL so arbitrary
    // classes from the pasteboard cannot be instantiated.
    if let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data),
        let url = archived as URL?, url.isFileURL
    {
        return url
    }

    // Some pasteboard bridges wrap the URL string in a property list instead
    // of archiving NSURL directly.
    if let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ), let url = pasteboardFileURL(fromPropertyList: propertyList) {
        return url
    }
    return nil
}

private func pasteboardFileURL(from value: String) -> URL? {
    let value = value.trimmingCharacters(
        in: .whitespacesAndNewlines.union(.controlCharacters)
    )
    if let url = URL(string: value), url.isFileURL {
        return url
    }
    if value.hasPrefix("/") {
        return URL(fileURLWithPath: value)
    }
    return nil
}

private func pasteboardFileURL(fromPropertyList value: Any) -> URL? {
    if let string = value as? String {
        return pasteboardFileURL(from: string)
    }
    if let values = value as? [Any] {
        return values.lazy.compactMap(pasteboardFileURL(fromPropertyList:)).first
    }
    if let values = value as? [String: Any] {
        return values.keys.sorted().lazy
            .compactMap { pasteboardFileURL(fromPropertyList: values[$0] as Any) }
            .first
    }
    return nil
}
