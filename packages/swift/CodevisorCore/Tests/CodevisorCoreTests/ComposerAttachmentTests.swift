import ACPKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CodevisorCore

@Suite("Composer attachments")
struct ComposerAttachmentTests {
    @Test("File URL pasteboard data decodes without object coercion")
    func pasteboardFileURLDataDecoding() async throws {
        let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")
        let provider = try #require(NSItemProvider(contentsOf: expected))
        let data = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
                data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? MissingRepresentationError())
                }
            }
        }

        #expect(decodePasteboardFileURL(data) == expected)
    }

    @Test("File URL pasteboard decoding rejects non-file and malformed data")
    func pasteboardFileURLDataValidation() throws {
        let remote = try #require(URL(string: "https://example.com/image.png"))

        #expect(decodePasteboardFileURL(remote.dataRepresentation) == nil)
        #expect(decodePasteboardFileURL(Data([0xFF, 0x00, 0xFF])) == nil)
    }

    @Test("File URL pasteboard decoding accepts cross-device string encodings")
    func pasteboardFileURLStringDecoding() throws {
        let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")

        #expect(decodePasteboardFileURL(Data("file:///tmp/Pasted%20Image.png\0".utf8)) == expected)
        #expect(decodePasteboardFileURL(Data("/tmp/Pasted Image.png\n".utf8)) == expected)
        #expect(
            decodePasteboardFileURL(
                try #require("file:///tmp/Pasted%20Image.png".data(using: .utf16))
            ) == expected
        )
    }

    @Test("File URL pasteboard decoding accepts an archived NSURL")
    func pasteboardArchivedFileURLDecoding() throws {
        let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: expected as NSURL,
            requiringSecureCoding: true
        )

        #expect(decodePasteboardFileURL(data) == expected)
    }

    @Test("File URL pasteboard decoding accepts property-list wrappers")
    func pasteboardPropertyListFileURLDecoding() throws {
        let expected = URL(fileURLWithPath: "/tmp/Pasted Image.png")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "file:///tmp/Pasted%20Image.png"],
            format: .binary,
            options: 0
        )

        #expect(decodePasteboardFileURL(data) == expected)
    }

    @MainActor
    @Test("Optimistic attachments keep their identity and are not persisted while empty")
    func optimisticAttachmentLifecycle() throws {
        let controller = SessionController(
            project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        let id = UUID()

        #expect(
            controller.beginLoadingAttachment(
                id: id,
                name: "Pasted image.jpeg",
                mimeType: "image/jpeg",
                kind: .image
            )
        )
        #expect(controller.composerAttachments.first?.id == id)
        #expect(controller.composerAttachments.first?.state == .loading)
        #expect(controller.draftSnapshot().attachments.isEmpty)

        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let resolutionFailure = controller.resolveLoadingAttachment(
            id: id,
            name: "cat.jpeg",
            mimeType: "image/jpeg",
            kind: .image,
            data: bytes
        )
        #expect(resolutionFailure == nil)

        let attachment = try #require(controller.composerAttachments.first)
        #expect(attachment.id == id)
        #expect(attachment.name == "cat.jpeg")
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.localData == bytes)
        #expect(attachment.state == .failed("Server unavailable"))
    }

    @MainActor
    @Test("File URL attachments appear synchronously while their bytes load")
    func fileURLAttachmentAppearsSynchronously() throws {
        let controller = SessionController(
            project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        let url = URL(fileURLWithPath: "/tmp/optimistic-image.png")

        controller.attachFileURLs([url])

        let attachment = try #require(controller.composerAttachments.first)
        #expect(attachment.name == "optimistic-image.png")
        #expect(attachment.kind == .image)
        #expect(attachment.localData.isEmpty)
        #expect(attachment.state == .loading)
    }

    @MainActor
    @Test("Discarding an unreadable paste stays local to the composer")
    func discardedPasteDoesNotBecomeSessionFailure() {
        let controller = SessionController(
            project: Project.fromFolder(URL(fileURLWithPath: "/tmp/attachment-tests")),
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        let id = UUID()
        #expect(
            controller.beginLoadingAttachment(
                id: id,
                name: "Pasted image.jpeg",
                mimeType: "image/jpeg",
                kind: .image
            )
        )

        #expect(controller.discardLoadingAttachment(id: id))
        #expect(controller.composerAttachments.isEmpty)
        #expect(controller.status == .idle)
    }

    private struct MissingRepresentationError: Error {}
}
