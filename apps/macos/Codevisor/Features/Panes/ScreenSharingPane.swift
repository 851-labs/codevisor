import AppKit
import Autocomplete
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
  let displaySearchFocus = Autocomplete.InputFocus()
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)? { didSet { model?.onFocusChanged = onFocusChanged } }
  var onFocus: (() -> Void)?
  var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)? {
    didSet { model?.onPreferencesChanged = onPreferencesChanged }
  }
  private var mounts = Set<UUID>()

  var showsDisplayPicker: Bool {
    guard let model else { return false }
    return ![.connecting, .reconnecting, .viewing].contains(model.phase)
  }

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
  @State private var query = ""

  var body: some View {
    Group {
      if let model = pane.model {
        if pane.showsDisplayPicker {
          displayPicker(model)
        } else {
          connection(model)
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
    .onChange(of: pane.showsDisplayPicker) { _, choosing in
      if choosing { query = ""; pane.focus() }
    }
  }

  private func displayPicker(_ model: ScreenSharingViewerModel) -> some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 16) {
          Autocomplete.Suggestions(query: $query, focus: pane.displaySearchFocus) {
            for display in model.displays {
              Autocomplete.Action(
                "\(display.name) · \(display.width) × \(display.height)", id: display.id, systemImage: "display"
              ) {
                model.selectDisplay(display.id)
                // Selecting a display already reconnects a previously connected pane.
                if model.phase == .ready { model.connect() }
              }
            }
          }
          .autocompleteSearchPrompt("Search screens")
          .autocompleteSearchLabel("Search available screens on \(pane.machineName)")
          .autocompleteEmptyMessage("No matching screens", noItems: "No screens available")
          .autocompleteLoadingState(model.phase == .loading ? .loading("Finding screens…") : .ready)
          .composerGlassSurface(cornerRadius: 18)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Available screens on \(pane.machineName)")

          if model.phase == .failed {
            VStack(spacing: 12) {
              if let message = model.message {
                Text(message).foregroundStyle(.secondary)
                  .multilineTextAlignment(.center).frame(maxWidth: 380)
              }
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
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(minHeight: geometry.size.height)
      }
    }
    .simultaneousGesture(
      TapGesture().onEnded {
        pane.onFocusChanged?(true)
        pane.focus()
      }
    )
  }

  private func connection(_ model: ScreenSharingViewerModel) -> some View {
    VStack(spacing: 0) {
      if let message = model.control?.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
      }
      if let message = model.clipboard?.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
      }
      ZStack {
        if let videoView = model.videoView { ScreenSharingNativeView(view: videoView) }
        if model.phase != .viewing {
          VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(
              model.phase == .reconnecting
                ? "Reconnecting to \(pane.machineName)…" : "Connecting to \(pane.machineName)…")
          }
          .padding(24)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct ScreenSharingNativeView: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
