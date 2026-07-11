import AppKit
import Observation
import UniformTypeIdentifiers
import HerdManCore
import os

/// Materializes attachment bytes as local files for SwiftUI's system-owned
/// Quick Look presentation. The native modifier owns all window chrome,
/// transitions, keyboard behavior, and dismissal.
@MainActor
@Observable
final class QuickLookController {
    private(set) var previewURL: URL?
    /// Quick Look may continue reading a replaced preview URL asynchronously,
    /// so retain every directory used by the active system preview until it closes.
    private var temporaryDirectories: [URL] = []
    private var presentationTask: Task<Void, Never>?
    private var presentationID = UUID()

    func present(_ item: QuickLookItem, attachmentStore: AttachmentImageStore?) {
        presentationTask?.cancel()
        presentationID = UUID()
        let presentationID = presentationID

        presentationTask = Task { [weak self] in
            guard let self else { return }
            let itemName = item.name
            let itemMimeType = item.mimeType
            do {
                let data: Data
                switch item {
                case let .local(localData, _, _):
                    data = localData
                case let .remote(fileId, _, _):
                    guard let attachmentStore else {
                        throw QuickLookError.attachmentUnavailable
                    }
                    data = try await attachmentStore.data(for: fileId)
                }

                try Task.checkCancellation()
                guard presentationID == self.presentationID else { return }

                let materialized = try await Task.detached(priority: .userInitiated) {
                    try Self.materialize(
                        data: data,
                        name: itemName,
                        mimeType: itemMimeType
                    )
                }.value
                guard presentationID == self.presentationID else {
                    try? FileManager.default.removeItem(at: materialized.directory)
                    return
                }
                self.temporaryDirectories.append(materialized.directory)
                self.previewURL = materialized.file
            } catch is CancellationError {
                // A newer attachment was selected while this one was loading.
            } catch {
                guard presentationID == self.presentationID else { return }
                self.showFailure(for: itemName, error: error)
            }
        }
    }

    /// Called by the native SwiftUI Quick Look modifier. The system writes nil
    /// when the user closes its preview.
    func updatePreviewURL(_ url: URL?) {
        guard previewURL != url else { return }
        previewURL = url
        guard url == nil else { return }

        presentationTask?.cancel()
        presentationTask = nil
        presentationID = UUID()
        scheduleTemporaryDirectoryCleanup()
    }

    func dismiss() {
        updatePreviewURL(nil)
    }

    private func scheduleTemporaryDirectoryCleanup() {
        let directories = temporaryDirectories
        temporaryDirectories.removeAll()
        Task.detached(priority: .utility) {
            // Let the system preview finish its closing animation before the
            // backing files disappear.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func showFailure(for name: String, error: Error) {
        Log.attachments.error(
            "Quick Look preparation failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Preview Attachment"
        alert.informativeText = "\(name) could not be prepared for Quick Look. \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    nonisolated private static func materialize(
        data: Data,
        name: String,
        mimeType: String
    ) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdMan-QuickLook", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            let file = directory.appendingPathComponent(
                safeFilename(name: name, mimeType: mimeType),
                isDirectory: false
            )
            try data.write(to: file, options: .atomic)
            return (directory, file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Keeps Quick Look's type inference intact while preventing attachment
    /// names from escaping their per-preview temporary directory.
    nonisolated private static func safeFilename(name: String, mimeType: String) -> String {
        var candidate = (name as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = candidate.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" {
                return "_"
            }
            return String(scalar)
        }.joined()

        if candidate.isEmpty || candidate == "." || candidate == ".." {
            candidate = "Attachment"
        }

        if (candidate as NSString).pathExtension.isEmpty,
           let inferredExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            candidate += ".\(inferredExtension)"
        }

        let pathExtension = String((candidate as NSString).pathExtension.prefix(32))
        guard !pathExtension.isEmpty else { return String(candidate.prefix(180)) }
        let stem = (candidate as NSString).deletingPathExtension
        let stemLimit = max(1, 179 - pathExtension.count)
        return "\(stem.prefix(stemLimit)).\(pathExtension)"
    }
}

private enum QuickLookError: LocalizedError {
    case attachmentUnavailable

    var errorDescription: String? {
        switch self {
        case .attachmentUnavailable:
            "The attachment is no longer available."
        }
    }
}
