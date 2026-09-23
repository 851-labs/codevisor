#if os(macOS)
  import AppKit
  import SwiftUI

  /// What the Native session scenario shows beside the video: the resident
  /// viewer's connection, written by `RigRunner` on its telemetry tick.
  @MainActor
  @Observable
  final class RigNativeSessionStatus {
    var line = "Starting…"
    var hudEnabled = true
    /// A `sample` is running: the window shows only the video for its duration.
    var sampling = false
  }

  /// The resident two-Mac viewer inside the shell window: the session's Metal
  /// view and HUD in the runner's surface, and a status line under it.
  struct RigNativeSessionView: View {
    let runner: RigRunner

    var body: some View {
      let status = runner.nativeSession
      VStack(spacing: 0) {
        ZStack {
          Color.black
          RigSurfaceView(view: runner.viewerSurface())
        }
        Divider()
        HStack {
          Text(status.line).font(.caption).lineLimit(1).truncationMode(.middle)
          Spacer()
          Button(status.hudEnabled ? "Hide HUD" : "Show HUD") { runner.setHUD(!status.hudEnabled) }
            .controlSize(.small)
          Text("H").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .navigationTitle("Native session")
    }
  }

  struct RigSurfaceView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
  }
#endif
