import AVKit
import CodevisorCore
import SwiftUI

struct FileVideoPlayer: View {
  let path: String
  let client: any CodevisorServerClienting
  @State private var phase = Phase.loading

  private enum Phase {
    case loading
    case ready(AVPlayer)
    case failed(String)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task(id: path) { await load() }
      .onDisappear(perform: pause)
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .loading:
      ProgressView("Loading video…")
    case let .ready(player):
      FileVideoSurface(player: player)
        .accessibilityLabel(FileDocumentLocation.name(path))
    case let .failed(message):
      ContentUnavailableView {
        Label("Video unavailable", systemImage: "video.slash")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { Task { await load() } }
      }
    }
  }

  private func load() async {
    phase = .loading
    do {
      phase = .ready(AVPlayer(url: try await FileMaterializer.url(path: path, client: client)))
    } catch {
      if !isTaskCancellation(error) { phase = .failed(serverErrorMessage(error)) }
    }
  }

  private func pause() {
    guard case let .ready(player) = phase else { return }
    player.pause()
  }
}

#if canImport(AppKit)
  private struct FileVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
      let view = AVPlayerView()
      view.controlsStyle = .floating
      view.player = player
      return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
      guard view.player !== player else { return }
      view.player = player
    }
  }
#else
  private struct FileVideoSurface: View {
    let player: AVPlayer

    var body: some View {
      VideoPlayer(player: player)
    }
  }
#endif
