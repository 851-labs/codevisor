import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

struct WorkspaceInspectorMediaView: View {
  let model: WorkspaceInspectorMediaModel
  let onRetry: () -> Void

  var body: some View {
    if model.media.isEmpty {
      WorkspaceInspectorMediaPlaceholder(
        phase: model.mediaPhase, emptyTitle: "No Media", systemImage: "photo.on.rectangle",
        emptyDescription: "Images and videos shared or captured in this workspace's chats appear here.",
        onRetry: onRetry
      )
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
          ForEach(model.media) { item in
            WorkspaceInspectorMediaTile(
              file: PreviewFile(
                source: .attachment(fileId: item.attachment.fileId),
                name: item.attachment.name,
                mimeType: item.attachment.mimeType,
                kind: item.isVideo ? .file : .image
              ),
              durationSeconds: item.durationSeconds
            )
            .onAppear {
              guard item.id == model.media.last?.id else { return }
              Task { await model.loadMoreMedia() }
            }
          }
        }
        .padding(10)
      }
    }
  }
}

private struct WorkspaceInspectorMediaTile: View {
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.quickLook) private var quickLook
  let file: PreviewFile
  let durationSeconds: Double?
  @State private var image: NSImage?

  var body: some View {
    Rectangle()
      .fill(.quaternary)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: file.isVideo ? "video" : "photo")
            .foregroundStyle(.tertiary)
        }
      }
      .overlay {
        if file.isVideo { VideoPlayBadge() }
      }
      .overlay(alignment: .bottomTrailing) {
        if file.isVideo, let durationSeconds {
          VideoDurationBadge(seconds: durationSeconds)
            .padding(4)
        }
      }
      .overlay {
        AttachmentLoadingOverlay(isLoading: isLoadingPreview)
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onTapGesture(perform: preview)
      .help(file.name)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(file.isVideo ? "Video \(file.name)" : file.name)
      .accessibilityAddTraits([.isImage, .isButton])
      .accessibilityAction(.default, preview)
      .accessibilityValue(isLoadingPreview ? "Loading" : "")
      .attachmentContextMenu(file: file, image: image)
      .task(id: file.name + file.mimeType + String(describing: file.source)) {
        guard let attachmentImages else { return }
        if let cached = await attachmentImages.cachedPreview(for: file) {
          image = cached.image
        }
        if let loaded = await attachmentImages.image(for: file), !Task.isCancelled {
          image = loaded.image
        }
      }
  }

  private var isLoadingPreview: Bool {
    quickLook?.isLoading(QuickLookItem(file)) ?? false
  }

  private func preview() {
    guard !isLoadingPreview else { return }
    quickLook?.present(QuickLookItem(file), attachmentStore: attachmentImages)
  }
}

struct WorkspaceInspectorMediaPlaceholder: View {
  let phase: WorkspaceInspectorMediaModel.Phase
  let emptyTitle: String
  let systemImage: String
  let emptyDescription: String
  let onRetry: () -> Void

  var body: some View {
    Group {
      switch phase {
      case .idle, .loading:
        ProgressView()
          .controlSize(.small)
      case .loaded:
        ContentUnavailableView(emptyTitle, systemImage: systemImage, description: Text(emptyDescription))
      case let .failed(message):
        ContentUnavailableView {
          Label("Couldn't Load", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again", action: onRetry)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
