import CodevisorCore
import CodevisorUI
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Staging picked media/files for the composer. Everything funnels through a
/// temporary file and `SessionController.attachFileURLs`, so the shared
/// staging path derives the mime type and kind, and the eager upload starts
/// exactly as it does on macOS.
@MainActor
enum ComposerAttachmentStaging {
  /// Resolves a pasted file URL into an existing optimistic placeholder.
  static func resolve(
    pastedURL url: URL,
    attachmentID: UUID,
    into controller: SessionController,
    onFailure: @escaping @MainActor (String, Attachment.Kind) -> Void
  ) {
    let type = UTType(filenameExtension: url.pathExtension)
    let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    let kind: Attachment.Kind = type?.conforms(to: .image) == true ? .image : .file
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
          return Result<Data, Error>.success(try Data(contentsOf: url))
        } catch {
          return Result<Data, Error>.failure(error)
        }
      }.value
      switch result {
      case let .success(data):
        let name = url.lastPathComponent.isEmpty ? "Pasted file" : url.lastPathComponent
        if kind == .image, let type {
          guard
            let prepared = await ComposerPasteProviderLoader.prepareImage(
              data: data,
              suggestedName: name,
              contentType: type
            )
          else {
            let message =
              "Couldn't prepare the pasted image. Try copying it again or choose it from Photos."
            if controller.discardLoadingAttachment(id: attachmentID) {
              onFailure(message, .image)
            }
            return
          }
          if let message = controller.resolveLoadingAttachment(
            id: attachmentID,
            name: prepared.name,
            mimeType: prepared.mimeType,
            kind: .image,
            data: prepared.data
          ) {
            onFailure(message, .image)
          }
          return
        }
        if let message = controller.resolveLoadingAttachment(
          id: attachmentID,
          name: name,
          mimeType: mimeType,
          kind: kind,
          data: data
        ) {
          onFailure(message, kind)
        }
      case let .failure(error):
        let message = "Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)"
        if controller.discardLoadingAttachment(id: attachmentID) {
          onFailure(message, kind)
        }
      }
    }
  }

  /// Copies security-scoped picker URLs into the app's temp directory (the
  /// shared staging path reads bytes asynchronously, after the scope would
  /// otherwise be released) and hands them to the controller. The reads and
  /// copies run off the main actor — reading a picked iCloud Drive file can
  /// block on a download — and unreadable files are skipped, as before.
  static func stage(pickedURLs urls: [URL], into controller: SessionController) {
    Task {
      let staged = await Task.detached(priority: .userInitiated) { () -> [URL] in
        var staged: [URL] = []
        for url in urls {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          guard let data = try? Data(contentsOf: url) else { continue }
          if let copy = writeTemporary(data: data, name: url.lastPathComponent) {
            staged.append(copy)
          }
        }
        return staged
      }.value
      guard !staged.isEmpty else { return }
      controller.attachFileURLs(staged)
    }
  }

  /// Loads PhotosPicker selections and stages them under a filename whose
  /// extension matches the asset's real type, so images, HEICs, and videos
  /// keep the right mime type.
  static func stage(photoItems items: [PhotosPickerItem], into controller: SessionController) async {
    for item in items {
      guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
      let type = item.supportedContentTypes.first
      let ext = type?.preferredFilenameExtension ?? "jpg"
      let base = type?.conforms(to: .movie) == true ? "Video" : "Photo"
      let name = "\(base) \(timestamp()).\(ext)"
      let url = await Task.detached(priority: .userInitiated) {
        writeTemporary(data: data, name: name)
      }.value
      if let url {
        controller.attachFileURLs([url])
      }
    }
  }

  static func stage(cameraImage image: UIImage, into controller: SessionController) {
    let name = "Photo \(timestamp()).jpg"
    Task {
      // JPEG-encoding a full-resolution capture and writing it out are
      // both too heavy for the main actor.
      let url = await Task.detached(priority: .userInitiated) { () -> URL? in
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return writeTemporary(data: data, name: name)
      }.value
      if let url {
        controller.attachFileURLs([url])
      }
    }
  }

  private nonisolated static func writeTemporary(data: Data, name: String) -> URL? {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerAttachments", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url =
        directory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter.string(from: Date())
  }
}

/// The staged-attachment strip above the composer input: image thumbnails and
/// file chips, each removable, with upload and failure state.
struct ComposerAttachmentStrip: View {
  @Bindable var controller: SessionController

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(controller.composerAttachments) { attachment in
          ComposerAttachmentChip(
            attachment: attachment,
            onRemove: { controller.removeAttachment(id: attachment.id) },
            onRetry: { controller.retryAttachment(id: attachment.id) }
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
  let attachment: ComposerAttachment
  let onRemove: () -> Void
  let onRetry: () -> Void

  @State private var thumbnail: UIImage?
  @State private var quickLookURL: QuickLookURL?

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
    .task(id: attachment.localData.count) {
      guard attachment.hasVisualPreview, thumbnail == nil else { return }
      let data = attachment.localData
      thumbnail = await Task.detached(priority: .userInitiated) {
        UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 320, height: 320))
      }.value
    }
    .sheet(item: $quickLookURL) { item in
      QuickLookPreview(url: item.url)
        .ignoresSafeArea()
        .presentationDragIndicator(.visible)
    }
  }

  private var thumbnailView: some View {
    Button(action: preview) {
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.secondary.opacity(0.12))
        if let thumbnail {
          Image(uiImage: thumbnail)
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
    .disabled(!canPreview)
    .opacity(isFailed ? 0.5 : 1)
    .accessibilityLabel("Preview \(attachment.name)")
    .accessibilityValue(isFailed ? "Upload failed" : "")
    .accessibilityHint(canPreview ? "Opens the attachment preview" : "Attachment is still loading")
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
            // At accessibility sizes, reflow to a second line and widen
            // rather than truncating harder as text grows.
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
      .disabled(!canPreview)
      .opacity(isFailed ? 0.5 : 1)
      .accessibilityLabel("Preview \(attachment.name)")
      .accessibilityValue(isFailed ? "Upload failed" : "")
      .accessibilityHint(
        canPreview ? "Opens the attachment preview" : "Attachment is still loading"
      )

      if let reason = failureReason {
        fileRetryButton(reason: reason)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }

  private var canPreview: Bool { !attachment.localData.isEmpty }

  private func preview() {
    guard canPreview else { return }
    let data = attachment.localData
    let name = attachment.name
    Task {
      guard let url = await materializeQuickLookURL(data: data, name: name) else { return }
      quickLookURL = QuickLookURL(url: url)
    }
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
    .padding(attachment.hasVisualPreview ? 6 : 0)
    .offset(attachment.hasVisualPreview ? .zero : CGSize(width: 5, height: -5))
    .accessibilityLabel("Remove \(attachment.name)")
  }
}

/// Camera capture for the attach menu. UIKit's picker is still the shortest
/// path to a single still capture on iOS.
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
