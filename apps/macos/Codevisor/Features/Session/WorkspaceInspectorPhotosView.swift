import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorPhotosView: View {
  let model: WorkspaceInspectorMediaModel
  let onRetry: () -> Void

  var body: some View {
    if model.photos.isEmpty {
      WorkspaceInspectorMediaPlaceholder(
        phase: model.photosPhase, emptyTitle: "No Photos", systemImage: "photo.on.rectangle",
        emptyDescription: "Images shared or captured in this workspace's chats appear here.",
        onRetry: onRetry
      )
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
          ForEach(model.photos) { photo in
            WorkspaceInspectorPhotoTile(
              file: PreviewFile(
                source: .attachment(fileId: photo.attachment.fileId),
                name: photo.attachment.name,
                mimeType: photo.attachment.mimeType,
                kind: .image
              )
            )
            .onAppear {
              guard photo.id == model.photos.last?.id else { return }
              Task { await model.loadMorePhotos() }
            }
          }
        }
        .padding(10)
      }
    }
  }
}

private struct WorkspaceInspectorPhotoTile: View {
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.quickLook) private var quickLook
  let file: PreviewFile
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
          Image(systemName: "photo")
            .foregroundStyle(.tertiary)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onTapGesture {
        _ = quickLook?.present(QuickLookItem(file), attachmentStore: attachmentImages)
      }
      .help(file.name)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(file.name)
      .accessibilityAddTraits([.isImage, .isButton])
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
