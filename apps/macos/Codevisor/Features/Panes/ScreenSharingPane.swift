import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import SwiftUI

@MainActor
final class ScreenSharingPane: Pane {
  let id: UUID
  let kind: PaneKind = .screenSharing
  let store: StoreOf<ScreenSharingViewer>?
  let machineName: String
  let isLocal: Bool
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)? { didSet { store?.endpoint?.onFocusChanged = onFocusChanged } }
  var onFocus: (() -> Void)?
  var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)?
  private var mounts = Set<UUID>()
  private var persistedRevision = 0
  private var observation: ObserveToken?

  /// The machine the pane streams from.
  var connectionName: String { machineName }

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    machineName = context.machine.name
    isLocal = context.machine.isLocal
    store = context.workspaceId.map { workspaceId in
      let client = context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
      return Store(initialState: ScreenSharingViewer.State(preferences: descriptor.screenSharing ?? .init())) {
        ScreenSharingViewer()
      } withDependencies: {
        $0[ScreenSharingViewerBackend.self] = .native(client: client, workspaceId: workspaceId, paneId: descriptor.id)
      }
    }
    guard let store else { return }
    // Each connection's endpoint carries the focus callback; preferences the
    // user changed here (and only those) are handed to the registry.
    observation = observe { [weak self] in
      guard let self else { return }
      store.endpoint?.onFocusChanged = self.onFocusChanged
      let revision = store.preferencesRevision
      guard revision != self.persistedRevision else { return }
      self.persistedRevision = revision
      self.onPreferencesChanged?(store.preferences)
    }
  }
  func makeView() -> AnyView { AnyView(ScreenSharingPaneView(pane: self)) }
  func focus() { if store?.lease?.phase != .controlling { onFocus?() } }
  func visibilityChanged(_ visible: Bool) { store?.send(visible ? .paneAppeared : .paneDisappeared) }
  func applyPreferences(_ preferences: ScreenSharingPanePreferences) { store?.send(.preferencesSynced(preferences)) }
  func willDelete() async {
    mounts = []
    await store?.send(.paneClosed).finish()
  }
  func detach() {
    mounts = []
    store?.send(.paneDisappeared)
  }
  func mounted(_ token: UUID) {
    mounts.insert(token)
    store?.send(.paneAppeared)
  }
  func unmounted(_ token: UUID) {
    mounts.remove(token)
    // SwiftUI reparents carried panes within the same presentation update.
    // Coalesce that handoff; a true navigation-away has no replacement mount.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.mounts.isEmpty else { return }
      self.store?.send(.paneDisappeared)
    }
  }
}

private struct ScreenSharingPaneView: View {
  let pane: ScreenSharingPane
  @Environment(\.theme) private var theme
  @State private var mount = UUID()

  var body: some View {
    Group {
      if let store = pane.store {
        if store.phase == .failed {
          failure(store)
        } else {
          connection(store)
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

  private func failure(_ store: StoreOf<ScreenSharingViewer>) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
      if let message = store.message {
        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
      }
      Button("Retry") { store.send(.retryButtonTapped) }
      if pane.isLocal {
        Button("Screen Recording Settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .simultaneousGesture(
      TapGesture().onEnded {
        pane.onFocusChanged?(true)
        pane.focus()
      }
    )
  }

  private func connection(_ store: StoreOf<ScreenSharingViewer>) -> some View {
    VStack(spacing: 0) {
      if let message = store.lease?.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
      }
      if let message = store.endpoint?.clipboard?.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
      }
      ZStack {
        if let endpoint = store.endpoint { ScreenSharingNativeView(view: endpoint.view) }
        if store.phase != .viewing {
          VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(
              store.phase == .reconnecting
                ? "Reconnecting to \(pane.connectionName)…" : "Connecting to \(pane.connectionName)…")
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
