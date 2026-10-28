import CodevisorCore
import CodevisorUI
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum ComposerAttachmentStaging {
  static func resolve(
    pastedURL url: URL,
    attachmentID: UUID,
    into controller: SessionController,
    onFailure: @escaping @MainActor (String, Attachment.Kind) -> Void
  ) {
    let type = UTType(filenameExtension: url.pathExtension)
    let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    let kind: Attachment.Kind = type?.conforms(to: .image) == true ? .image : .file
    let name = url.lastPathComponent.isEmpty ? "Pasted file" : url.lastPathComponent
    let files = controller.attachmentFiles
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          return Result<URL, Error>.success(
            try files.stageCopy(of: url, id: attachmentID, name: name))
        } catch {
          return Result<URL, Error>.failure(error)
        }
      }.value
      switch result {
      case let .success(stagedURL):
        if kind == .image, let type {
          guard
            let prepared = await ComposerPasteProviderLoader.prepareImage(
              stagedFileURL: stagedURL,
              attachmentID: attachmentID,
              files: files,
              suggestedName: name,
              contentType: type
            )
          else {
            files.remove(id: attachmentID)
            let message =
              "Couldn't prepare the pasted image. Try copying it again or choose it from Photos."
            if controller.attachments.discardLoadingAttachment(id: attachmentID) {
              onFailure(message, .image)
            }
            return
          }
          if let message = controller.attachments.resolveLoadingAttachment(
            id: attachmentID,
            name: prepared.name,
            mimeType: prepared.mimeType,
            kind: .image,
            stagedFileURL: prepared.fileURL
          ) {
            onFailure(message, .image)
          }
          return
        }
        if let message = controller.attachments.resolveLoadingAttachment(
          id: attachmentID,
          name: name,
          mimeType: mimeType,
          kind: kind,
          stagedFileURL: stagedURL
        ) {
          onFailure(message, kind)
        }
      case let .failure(error):
        let message = "Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)"
        if controller.attachments.discardLoadingAttachment(id: attachmentID) {
          onFailure(message, kind)
        }
      }
    }
  }

  static func stage(pickedURLs urls: [URL], into controller: SessionController) {
    let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
    Task {
      await controller.attachments.attachFileURLs(urls).value
      for url in scoped { url.stopAccessingSecurityScopedResource() }
    }
  }

  static func stage(photoItems items: [PhotosPickerItem], into controller: SessionController) {
    let stamp = timestamp()
    for item in items {
      let pickedType = item.supportedContentTypes.first
      let base = pickedType?.conforms(to: .movie) == true ? "Video" : "Photo"
      let placeholder = metadata(base: base, stamp: stamp, type: pickedType)
      let id = controller.attachments.attachLoading(
        name: placeholder.name,
        mimeType: placeholder.mimeType,
        kind: placeholder.kind
      ) { id, files in
        guard let picked = try await item.loadTransferable(type: PickedMediaFile.self) else {
          throw PickedMediaUnavailable()
        }
        defer { try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent()) }
        let loaded = metadata(
          base: base,
          stamp: stamp,
          type: UTType(filenameExtension: picked.url.pathExtension) ?? pickedType
        )
        return LoadedAttachmentFile(
          fileURL: try files.stageCopy(of: picked.url, id: id, name: loaded.name),
          name: loaded.name,
          mimeType: loaded.mimeType,
          kind: loaded.kind
        )
      }
      if let id {
        Task {
          guard let preview = try? await item.loadTransferable(type: PickerPreviewImage.self) else { return }
          controller.attachments.showLoadingPreview(preview.data, for: id)
        }
      }
    }
  }

  static func stage(cameraImage image: UIImage, into controller: SessionController) {
    let name = "Photo \(timestamp()).jpg"
    controller.attachments.attachLoading(name: name, mimeType: "image/jpeg", kind: .image) { id, files in
      guard let data = image.jpegData(compressionQuality: 0.9) else { throw PickedMediaUnavailable() }
      return LoadedAttachmentFile(
        fileURL: try files.stage(data: data, id: id, name: name),
        name: name,
        mimeType: "image/jpeg",
        kind: .image
      )
    }
  }

  private nonisolated static func metadata(
    base: String,
    stamp: String,
    type: UTType?
  ) -> (name: String, mimeType: String, kind: Attachment.Kind) {
    let ext = type?.preferredFilenameExtension ?? (base == "Video" ? "mov" : "jpg")
    return (
      "\(base) \(stamp).\(ext)",
      type?.preferredMIMEType ?? "application/octet-stream",
      type?.conforms(to: .image) == true ? .image : .file
    )
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter.string(from: Date())
  }
}

nonisolated private struct PickedMediaUnavailable: Error {}

nonisolated private struct PickerPreviewImage: Transferable {
  let data: Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: UTType(importedAs: "com.apple.private.photos.thumbnail.standard")) {
      PickerPreviewImage(data: $0)
    }
  }
}

nonisolated private struct PickedMediaFile: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .data) { received in
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ComposerAttachments", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(received.file.lastPathComponent)
      try FileManager.default.copyItem(at: received.file, to: url)
      return PickedMediaFile(url: url)
    }
  }
}

struct ComposerAttachmentStrip: View {
  @Bindable var controller: SessionController

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(controller.composerAttachments) { attachment in
          ComposerAttachmentChip(
            attachment: attachment,
            onRemove: { controller.attachments.removeAttachment(id: attachment.id) },
            onRetry: { controller.attachments.retryAttachment(id: attachment.id) }
          )
        }
      }
      .padding(.vertical, 2)
    }
    .scrollClipDisabled()
  }
}

private struct ComposerAttachmentChip: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.attachmentImages) private var attachmentImages
  let attachment: ComposerAttachment
  let onRemove: () -> Void
  let onRetry: () -> Void

  @State private var thumbnail: UIImage?
  @State private var loadingPreview: UIImage?
  @State private var quickLookURL: URL?

  private var failureReason: String? {
    if case let .failed(reason) = attachment.state { return reason }
    return nil
  }

  private var isFailed: Bool {
    failureReason != nil
  }

  private var isBusy: Bool {
    attachment.state == .loading || attachment.state == .uploading
  }

  var body: some View {
    Group {
      if attachment.hasVisualPreview {
        thumbnailView
      } else {
        fileChip
      }
    }
    .overlay(alignment: .topTrailing) { removeButton }
    .overlay {
      if isBusy {
        ProgressView()
          .controlSize(.small)
          .padding(4)
          .background(.ultraThinMaterial, in: Circle())
          .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .bottom) {
      if let reason = failureReason, attachment.hasVisualPreview {
        visualRetryButton(reason: reason)
          .padding(6)
      }
    }
    .transcriptSendAttachmentSource(
      id: attachment.sentFileID, image: thumbnail, cornerRadius: 16, sentSize: sentSize
    )
    .task(id: attachment.fileURL) {
      guard attachment.hasVisualPreview, thumbnail == nil, let fileURL = attachment.fileURL else {
        return
      }
      let isVideo = attachment.isVideo
      let isPDF = attachment.isPDF
      let image = await Task.detached(priority: .userInitiated) {
        await attachmentPreviewImage(fileURL: fileURL, isVideo: isVideo, isPDF: isPDF)
      }.value
      guard !Task.isCancelled else { return }
      thumbnail = image
    }
    .task(id: attachment.loadingPreviewData) {
      guard let data = attachment.loadingPreviewData, loadingPreview == nil else { return }
      let image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
      guard !Task.isCancelled else { return }
      loadingPreview = image
    }
    .task(id: attachment.uploadedFileID) {
      guard attachment.fileURL == nil, attachment.isImage, thumbnail == nil,
        case let .uploaded(ref) = attachment.state
      else { return }
      thumbnail = await attachmentImages?.image(for: PreviewFile(attachment: ref.attachment))?.image
    }
    .attachmentQuickLookPreview($quickLookURL)
  }

  private var sentSize: CGSize {
    guard attachment.hasVisualPreview else { return .zero }
    let aspectRatio = thumbnail.map { $0.size.width / max(1, $0.size.height) }
    return AttachmentThumbnailView.sentSize(aspectRatio: aspectRatio, isPDF: attachment.isPDF)
  }

  private var previewHint: String {
    if canPreview { return "Opens the attachment preview" }
    return isBusy ? "Attachment is still loading" : ""
  }

  private var thumbnailView: some View {
    Button(action: preview) {
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.secondary.opacity(0.12))
        if let image = thumbnail ?? loadingPreview {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          Image(systemName: attachment.isVideo ? "video" : "photo")
            .font(.title3)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: 96, height: 96)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .pointerHighlight(RoundedRectangle(cornerRadius: 16))
    .allowsHitTesting(canPreview)
    .opacity(isFailed ? 0.5 : 1)
    .accessibilityLabel("Preview \(attachment.name)")
    .accessibilityValue(isFailed ? "Upload failed" : "")
    .accessibilityHint(previewHint)
  }

  private var fileChip: some View {
    HStack(spacing: 6) {
      Button(action: preview) {
        HStack(spacing: 6) {
          Image(systemName: "doc")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(attachment.name)
            .font(.caption)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .truncationMode(.middle)
            .frame(
              maxWidth: dynamicTypeSize.isAccessibilitySize ? 240 : 140,
              alignment: .leading
            )
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .allowsHitTesting(canPreview)
      .opacity(isFailed ? 0.5 : 1)
      .accessibilityLabel("Preview \(attachment.name)")
      .accessibilityValue(isFailed ? "Upload failed" : "")
      .accessibilityHint(previewHint)

      if let reason = failureReason {
        fileRetryButton(reason: reason)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }

  private var canPreview: Bool { attachment.fileURL != nil }

  private func preview() {
    guard let fileURL = attachment.fileURL else { return }
    quickLookURL = fileURL
  }

  private func visualRetryButton(reason: String) -> some View {
    Button(action: onRetry) {
      Label("Retry", systemImage: "exclamationmark.circle.fill")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.black.opacity(0.72), in: Capsule())
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .expandedHitTarget(base: 28)
    .accessibilityLabel("Retry uploading \(attachment.name)")
    .accessibilityHint(reason)
  }

  private func fileRetryButton(reason: String) -> some View {
    Button(action: onRetry) {
      Label("Retry", systemImage: "exclamationmark.circle.fill")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.red.opacity(0.1), in: Capsule())
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .expandedHitTarget(base: 28)
    .accessibilityLabel("Retry uploading \(attachment.name)")
    .accessibilityHint(reason)
  }

  private var removeButton: some View {
    Button(action: onRemove) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: 26, height: 26)
        .background(Circle().fill(.white))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .padding(attachment.hasVisualPreview ? 6 : 0)
    .offset(attachment.hasVisualPreview ? .zero : CGSize(width: 5, height: -5))
    .accessibilityLabel("Remove \(attachment.name)")
  }
}

struct CameraPicker: UIViewControllerRepresentable {
  let onCapture: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(onCapture: onCapture, dismiss: { dismiss() })
  }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onCapture: (UIImage) -> Void
    private let dismiss: () -> Void

    init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
      self.onCapture = onCapture
      self.dismiss = dismiss
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage {
        onCapture(image)
      }
      dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      dismiss()
    }
  }
}
