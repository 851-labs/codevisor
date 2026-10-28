import Foundation
import os

@MainActor
final class AttachmentUploads {
  private var tasks: [UUID: Task<Void, Never>] = [:]

  func start(
    _ attachment: ComposerAttachment,
    client: any CodevisorServerClienting,
    fileURL: URL,
    completed: @escaping (ComposerAttachment.State) -> Void
  ) {
    tasks[attachment.id] = Task { [weak self] in
      do {
        let metadata = try await client.uploadFile(
          name: attachment.name,
          mimeType: attachment.mimeType,
          fileURL: fileURL
        )
        guard !Task.isCancelled else { return }
        completed(.uploaded(metadata.attachmentRef))
      } catch {
        guard !Task.isCancelled else { return }
        Log.attachments.error(
          "attachment upload failed for \(attachment.name, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        completed(.failed(humanServerErrorMessage(error, fallback: "The server didn’t accept it.")))
      }
      self?.tasks[attachment.id] = nil
    }
  }

  func cancel(id: UUID) {
    tasks[id]?.cancel()
    tasks[id] = nil
  }

  func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  func waitForCurrentUploads() async {
    for task in tasks.values { await task.value }
  }
}
