import AppKit
import Autocomplete
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
  let displaySearchFocus = Autocomplete.InputFocus()
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)? { didSet { store?.endpoint?.onFocusChanged = onFocusChanged } }
  var onFocus: (() -> Void)?
  var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)?
  private var mounts = Set<UUID>()
  private var persistedRevision = 0
  private var observation: ObserveToken?

  var showsDisplayPicker: Bool { store?.showsDisplayPicker ?? false }

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    machineName = context.machine.name
    isLocal = context.machine.isLocal
    store = context.workspaceId.map { workspaceId in
      let client = context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
      return Store(initialState: ScreenSharingViewer.State(preferences: descriptor.screenSharing ?? .init())) {
        ScreenSharingViewer()
      } withDependencies: {
        $0[ScreenSharingViewerBackend.self] = ScreenSharingViewerBackend.native(
          client: client, workspaceId: workspaceId, paneId: descriptor.id
        )
        .dispatchingVNC { target in await ScreenSharingVNCCredentials.liveValue.password(target.credentialAccount) }
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
  @State private var query = ""

  /// The VNC server's name while it is the selected display, else the machine's.
  private var connectionName: String {
    if let store = pane.store, let target = store.preferences.vnc, store.selectedDisplayId == target.displayId {
      return target.displayName
    }
    return pane.machineName
  }

  var body: some View {
    Group {
      if let store = pane.store {
        if store.showsDisplayPicker {
          displayPicker(store)
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
    .onChange(of: pane.showsDisplayPicker) { _, choosing in
      if choosing { query = ""; pane.focus() }
    }
  }

  private func displayPicker(_ store: StoreOf<ScreenSharingViewer>) -> some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 16) {
          Autocomplete.Suggestions(query: $query, focus: pane.displaySearchFocus) {
            for display in store.displays {
              let isVNC = ScreenSharingVNCTarget(displayId: display.id) != nil
              Autocomplete.Action(
                display.width > 0 ? "\(display.name) · \(display.width) × \(display.height)" : display.name,
                id: display.id, systemImage: isVNC ? "network" : "display"
              ) {
                store.send(.displaySelected(display.id))
                // Selecting a display already reconnects a previously connected pane.
                if store.phase == .ready { store.send(.connectButtonTapped) }
              }
            }
          }
          .autocompleteSearchPrompt("Search screens")
          .autocompleteSearchLabel("Search available screens on \(pane.machineName)")
          .autocompleteEmptyMessage("No matching screens", noItems: "No screens available")
          .autocompleteLoadingState(store.phase == .loading ? .loading("Finding screens…") : .ready)
          .composerGlassSurface(cornerRadius: 18)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Available screens on \(pane.machineName)")

          VNCServerForm(store: store)

          if store.phase == .failed {
            VStack(spacing: 12) {
              if let message = store.message {
                Text(message).foregroundStyle(.secondary)
                  .multilineTextAlignment(.center).frame(maxWidth: 380)
              }
              Button("Retry") { store.send(.retryButtonTapped) }
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
              store.phase == .reconnecting ? "Reconnecting to \(connectionName)…" : "Connecting to \(connectionName)…")
          }
          .padding(24)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// Enter a standard VNC server (host, port, password) or forget the saved one.
/// The password goes to the Keychain through the reducer; only the target is
/// persisted with the pane.
private struct VNCServerForm: View {
  let store: StoreOf<ScreenSharingViewer>
  @State private var host = ""
  @State private var port = String(ScreenSharingVNCTarget.defaultPort)
  @State private var password = ""

  private var target: ScreenSharingVNCTarget? {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, let port = UInt16(port.trimmingCharacters(in: .whitespaces)) else { return nil }
    return ScreenSharingVNCTarget(host: host, port: port)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("VNC server").font(.headline)
      if let saved = store.preferences.vnc {
        HStack {
          Label(saved.displayName, systemImage: "network").foregroundStyle(.secondary)
          Spacer()
          Button("Forget") { store.send(.vncTargetRemoved) }
        }
      }
      HStack(spacing: 8) {
        TextField("Host", text: $host).frame(minWidth: 160)
        TextField("Port", text: $port).frame(width: 64)
        SecureField("Password", text: $password).frame(minWidth: 120)
        Button("Connect", action: connect).disabled(target == nil)
      }
      .textFieldStyle(.roundedBorder)
      .onSubmit(connect)
      Text(
        "Any RFB 3.x server: macOS Screen Sharing with “VNC viewers may control screen with password”, TigerVNC, RealVNC…"
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .composerGlassSurface(cornerRadius: 18)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Connect to a VNC server")
  }

  private func connect() {
    guard let target else { return }
    store.send(.vncTargetSubmitted(target, password: password.isEmpty ? nil : password))
    password = ""
  }
}

private struct ScreenSharingNativeView: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
