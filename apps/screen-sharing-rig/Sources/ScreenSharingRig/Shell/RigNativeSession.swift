#if os(macOS)
  import AppKit
  import SwiftUI

  @MainActor
  @Observable
  final class RigNativeSessionStatus {
    var line = "Starting…"
    var hudEnabled = true
    var sampling = false
  }

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
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .navigationTitle("Native session")
      .toolbar {
        ToolbarItem(id: "rig.native.hud", placement: .primaryAction) {
          Toggle(isOn: Binding(get: { status.hudEnabled }, set: { runner.setHUD($0) })) {
            Label("HUD", systemImage: "gauge.with.dots.needle.33percent")
          }
          .help("Show or hide the HUD (H)")
        }
      }
    }
  }

  struct RigSurfaceView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
  }
#endif
