import CodevisorCore
import SwiftUI

struct FileImageViewer: View {
  let path: String
  let client: any CodevisorServerClienting
  var poster: OSImage?
  @State private var phase = Phase.loading

  private enum Phase {
    case loading
    case loaded(OSImage)
    case undecodable(size: Int)
    case failed(String)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task(id: path) { await load() }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .loading:
      FileImagePoster(poster: poster)
    case let .loaded(image):
      ZoomableImage(image: image)
        .accessibilityLabel(FileDocumentLocation.name(path))
        .accessibilityAddTraits(.isImage)
    case let .undecodable(size):
      FileMediaPreview(path: path, client: client, size: size)
    case let .failed(message):
      ContentUnavailableView("Preview unavailable", systemImage: "photo", description: Text(message))
    }
  }

  private func load() async {
    phase = .loading
    do {
      let bytes = try await FileDocumentLocation.data(path: path, client: client)
      let image = await Self.decode(bytes)
      try Task.checkCancellation()
      phase = image.map(Phase.loaded) ?? .undecodable(size: bytes.count)
    } catch {
      if !isTaskCancellation(error) { phase = .failed(serverErrorMessage(error)) }
    }
  }

  @concurrent
  nonisolated private static func decode(_ bytes: Data) async -> OSImage? {
    OSImage(data: bytes)
  }
}

private struct FileImagePoster: View {
  let poster: OSImage?

  var body: some View {
    if let poster {
      platformImage(poster)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .overlay(alignment: .bottom) { ProgressView().controlSize(.small).padding(16) }
    } else {
      ProgressView("Loading preview…")
    }
  }

  private func platformImage(_ image: OSImage) -> Image {
    #if canImport(AppKit)
      Image(nsImage: image)
    #else
      Image(uiImage: image)
    #endif
  }
}
