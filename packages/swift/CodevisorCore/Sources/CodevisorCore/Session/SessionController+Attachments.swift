import Foundation
import ACPKit
import UniformTypeIdentifiers
import os

extension SessionController {
    // MARK: - Attachments

    static public let maxAttachments = 10

    public func attachFileURLs(_ urls: [URL]) {
        for url in urls {
            attachFileURL(url)
        }
    }

    /// Stages one dropped/picked file. The bytes are read off the main
    /// thread so a large file or one on a slow network volume does not freeze
    /// the run loop.
    private func attachFileURL(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: Attachment.Kind =
            (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
            ? .image
            : .file
        Task { [weak self] in
            let result: (data: Data?, readError: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    return (try Data(contentsOf: url), nil)
                } catch {
                    return (nil, String(describing: error))
                }
            }.value
            guard let self else { return }
            if let data = result.data {
                self.stageAttachment(name: url.lastPathComponent, mimeType: mimeType, kind: kind, data: data)
            } else {
                Log.attachments.error(
                    "attachment read failed for \(url.lastPathComponent, privacy: .public): \(result.readError ?? "unknown", privacy: .public)"
                )
                self.stageAttachment(
                    name: url.lastPathComponent, mimeType: mimeType, kind: kind,
                    data: Data(),
                    failureMessage:
                        "Couldn't read “\(url.lastPathComponent)”. Check that you have permission to open it, then try again."
                )
            }
        }
    }

    public func attachImageData(_ data: Data, suggestedName: String? = nil) {
        let name = suggestedName ?? "Pasted image \(Self.pastedImageFormatter.string(from: Date())).png"
        stageAttachment(name: name, mimeType: "image/png", kind: .image, data: data)
    }

    public func removeAttachment(id: UUID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        composerAttachments.removeAll { $0.id == id }
    }

    public func retryAttachment(id: UUID) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
            case .failed = composerAttachments[index].state
        else { return }
        composerAttachments[index].state = .uploading
        startUpload(composerAttachments[index])
    }

    /// Fetches stored attachment bytes through this session's server client —
    /// History thumbnails and Quick Look load through here so auth carries
    /// over for remote servers.
    public func fileData(id: String) async throws -> Data {
        guard let serverClient else { throw SessionControllerError.serverUnavailable }
        return try await serverClient.fileData(id: id)
    }

    /// Fetches either immutable attachment bytes or a live path from the
    /// machine that owns this session.
    public func fileData(for source: PreviewFile.Source) async throws -> Data {
        guard let serverClient else { throw SessionControllerError.serverUnavailable }
        switch source {
        case let .attachment(fileId):
            return try await serverClient.fileData(id: fileId)
        case let .serverPath(path):
            guard let sessionId = serverSession?.id else {
                throw SessionControllerError.serverUnavailable
            }
            return try await serverClient.fileData(sessionId: sessionId, path: path)
        }
    }

    /// Namespaces device-local preview caches by both the machine and the
    /// authoritative cwd. A relative path in two worktrees must never collide.
    public var previewCacheNamespace: String {
        "\(project.serverId):\(sessionCwdURL.standardizedFileURL.path)"
    }

    /// Immutable attachments are versioned by id. Live paths use the server's
    /// HEAD validator so a same-named file can replace an older thumbnail.
    public func fileVersion(for source: PreviewFile.Source) async throws -> String? {
        switch source {
        case let .attachment(fileId):
            return "attachment:\(fileId)"
        case let .serverPath(path):
            guard let serverClient, let sessionId = serverSession?.id else {
                throw SessionControllerError.serverUnavailable
            }
            return try await serverClient.fileVersion(sessionId: sessionId, path: path)
        }
    }

    private func stageAttachment(
        name: String, mimeType: String, kind: Attachment.Kind, data: Data,
        failureMessage: String? = nil
    ) {
        guard composerAttachments.count < Self.maxAttachments else {
            status = .failed("A message can carry at most \(Self.maxAttachments) attachments.")
            return
        }
        var attachment = ComposerAttachment(
            id: UUID(),
            name: name,
            mimeType: mimeType,
            kind: kind,
            localData: data,
            state: .uploading
        )
        if let failureMessage {
            attachment.state = .failed(failureMessage)
            composerAttachments.append(attachment)
            return
        }
        composerAttachments.append(attachment)
        startUpload(attachment)
    }

    func startUpload(_ attachment: ComposerAttachment) {
        guard let serverClient else {
            setAttachmentState(attachment.id, .failed("Server unavailable"))
            return
        }
        uploadTasks[attachment.id] = Task { [weak self] in
            do {
                let metadata = try await serverClient.uploadFile(
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    data: attachment.localData
                )
                guard !Task.isCancelled else { return }
                self?.setAttachmentState(attachment.id, .uploaded(metadata.attachmentRef))
            } catch {
                guard !Task.isCancelled else { return }
                self?.setAttachmentState(attachment.id, .failed(serverErrorMessage(error)))
            }
            self?.uploadTasks[attachment.id] = nil
        }
    }

    private func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else { return }
        composerAttachments[index].state = state
    }

    /// Waits for in-flight uploads, then returns the attachments to send —
    /// nil (with a surfaced status) if any upload failed.
    func collectAttachmentsForSend() async -> [Attachment]? {
        for task in uploadTasks.values {
            await task.value
        }
        var attachments: [Attachment] = []
        for staged in composerAttachments {
            switch staged.state {
            case let .uploaded(ref):
                attachments.append(ref.attachment)
            case .failed:
                status = .failed("An attachment failed to upload. Retry or remove it, then send again.")
                return nil
            case .uploading:
                // Unreachable: awaiting the tasks above settles every state.
                return nil
            }
        }
        return attachments
    }

    private static let pastedImageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}
