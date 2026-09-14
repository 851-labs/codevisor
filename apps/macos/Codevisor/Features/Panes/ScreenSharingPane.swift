import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

@MainActor
final class ScreenSharingPane: Pane {
  let id: UUID
  let kind: PaneKind = .screenSharing
  let model: ScreenSharingViewerModel?
  let machineName: String
  let isLocal: Bool
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)? { didSet { model?.onFocusChanged = onFocusChanged } }
  var onFocus: (() -> Void)?
  var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)? {
    didSet { model?.onPreferencesChanged = onPreferencesChanged }
  }
  private var mounts = Set<UUID>()

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    machineName = context.machine.name
    isLocal = context.machine.isLocal
    model = context.workspaceId.map {
      ScreenSharingViewerModel(
        client: context.client ?? CodevisorServerClient(config: context.machine.serverConfig),
        workspaceId: $0, paneId: descriptor.id, preferences: descriptor.screenSharing ?? .init())
    }
  }
  func makeView() -> AnyView { AnyView(ScreenSharingPaneView(pane: self)) }
  func focus() { if model?.control?.state != .controlling { onFocus?() } }
  func visibilityChanged(_ visible: Bool) { model?.setVisible(visible) }
  func willDelete() async { mounts = []; await model?.close() }
  func detach() { mounts = []; model?.setVisible(false) }
  func mounted(_ token: UUID) { mounts.insert(token); model?.setVisible(true) }
  func unmounted(_ token: UUID) {
    mounts.remove(token)
    // SwiftUI reparents carried panes within the same presentation update.
    // Coalesce that handoff; a true navigation-away has no replacement mount.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.mounts.isEmpty else { return }
      self.model?.setVisible(false)
    }
  }
}

private struct ScreenSharingPaneView: View {
  let pane: ScreenSharingPane
  @Environment(\.theme) private var theme
  @State private var mount = UUID()

  var body: some View {
    Group {
      if let model = pane.model {
        VStack(spacing: 0) {
          ScreenSharingToolbar(model: model, machineName: pane.machineName)
          if let message = model.control?.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
          }
          if let message = model.clipboard?.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
          }
          Divider()
          ZStack {
            if let videoView = model.videoView { ScreenSharingNativeView(view: videoView) }
            if model.phase != .viewing {
              VStack(spacing: 12) {
                if model.phase == .loading || model.phase == .connecting || model.phase == .reconnecting {
                  ProgressView().controlSize(.small)
                  Text(
                    model.phase == .loading
                      ? "Finding displays…"
                      : model.phase == .reconnecting
                        ? "Reconnecting to \(pane.machineName)…" : "Connecting to \(pane.machineName)…")
                } else {
                  Image(systemName: "display").font(.system(size: 32)).foregroundStyle(.secondary)
                  Text("Screen Sharing").font(.headline)
                  Text(model.message ?? "Choose a display to view on \(pane.machineName).")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                  if model.phase == .failed {
                    Button("Retry") { model.refresh() }
                    if pane.isLocal {
                      Button("Screen Recording Settings") {
                        if let url = URL(
                          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        {
                          NSWorkspace.shared.open(url)
                        }
                      }
                    }
                  }
                }
              }
              .padding(24)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ContentUnavailableView(
          "Screen Sharing unavailable", systemImage: "display",
          description: Text("Open this pane in a workspace connected to a Mac."))
      }
    }
    .background(theme.paneBackground)
    .onAppear { pane.mounted(mount) }
    .onDisappear { pane.unmounted(mount) }
  }
}

private struct ScreenSharingNativeView: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
