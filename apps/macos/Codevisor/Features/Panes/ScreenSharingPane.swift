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
  private var persistedResolutionRevision = 0
  private var recordedViewing = false
  /// The endpoint the machine's sound settings were last applied to.
  private var soundAppliedTo: ObjectIdentifier?
  private let machineId: String
  /// How the machine is reached and where, for the settings sheet (851-2367).
  private let connection: (kind: String, address: String?)
  private var observation: ObserveToken?

  /// The machine the pane streams from.
  var connectionName: String { machineName }

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    machineName = context.machine.name
    machineId = context.machine.id
    isLocal = context.machine.isLocal
    connection = Self.connection(of: context.machine)
    store = context.workspaceId.map { workspaceId in
      let client = context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
      let state = ScreenSharingViewer.State(
        preferences: descriptor.screenSharing ?? .init(),
        dynamicResolution: ScreenSharingMachinePreferences().dynamicResolution(machineId: context.machine.id))
      return Store(initialState: state) {
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
      // Each new connection plays the machine's sound as its settings say (851-2379).
      if let endpoint = store.endpoint, let audio = endpoint.audio, self.soundAppliedTo != ObjectIdentifier(endpoint) {
        self.soundAppliedTo = ObjectIdentifier(endpoint)
        let saved = ScreenSharingMachinePreferences().sound(machineId: self.machineId)
        audio.apply(.init(enabled: saved.enabled, volume: saved.volume))
      }
      // Video arriving is what "last connected" means in the settings sheet.
      let viewing = store.phase == .viewing
      if viewing, !self.recordedViewing {
        ScreenSharingMachinePreferences().setLastConnected(Date(), machineId: self.machineId)
      }
      self.recordedViewing = viewing
      // Dynamic Resolution is the machine's, not the pane's (851-2340).
      if store.dynamicResolutionRevision != self.persistedResolutionRevision {
        self.persistedResolutionRevision = store.dynamicResolutionRevision
        ScreenSharingMachinePreferences().setDynamicResolution(store.dynamicResolution, machineId: self.machineId)
      }
      let revision = store.preferencesRevision
      guard revision != self.persistedRevision else { return }
      self.persistedRevision = revision
      self.onPreferencesChanged?(store.preferences)
    }
  }
  func makeView() -> AnyView { AnyView(ScreenSharingPaneView(pane: self)) }

  /// The machine's settings as the sheet shows them (851-2367). The connection is the
  /// machine's codevisor-server's to define, so only the viewer's choices are editable.
  func machineSettings() -> ScreenSharingMachineSettings {
    var settings = ScreenSharingMachineSettings(
      name: machineName, connection: connection.kind, address: connection.address,
      dynamicResolution: store?.dynamicResolution
        ?? ScreenSharingMachinePreferences().dynamicResolution(
          machineId: machineId),
      displays: store?.displays.map { .init(id: $0.id, name: $0.name) } ?? [],
      preferredDisplayId: store?.selectedDisplayId ?? store?.preferences.preferredDisplayId,
      lastConnected: ScreenSharingMachinePreferences().lastConnected(machineId: machineId),
      sound: store?.endpoint?.audio.map { .init(enabled: $0.enabled, volume: $0.volume) })
    settings.dynamicResolutionNote = Self.dynamicResolutionNote(store?.endpoint)
    return settings
  }

  /// Why Dynamic Resolution can't apply on this connection (851-2368), for the settings sheet.
  static func dynamicResolutionNote(_ endpoint: ScreenSharingViewerEndpoint?) -> String? {
    guard let endpoint else { return nil }
    if !endpoint.supportsDynamicResolution || endpoint.resolutionAvailability.available == false {
      return "This machine can't change its resolution over this connection."
    }
    return nil
  }

  /// Done in the sheet: Dynamic Resolution applies as the toolbar toggle does (and is saved for
  /// the machine); another display reconnects to it and is remembered for the pane.
  func applyMachineSettings(_ changes: ScreenSharingMachineSettingsChanges) {
    guard let store else { return }
    if let enabled = changes.dynamicResolution, enabled != store.dynamicResolution {
      store.send(.dynamicResolutionToggled)
    }
    if let sound = changes.sound {
      ScreenSharingMachinePreferences().setSound(enabled: sound.enabled, volume: sound.volume, machineId: machineId)
      store.endpoint?.audio?.apply(sound)
    }
    if let display = changes.preferredDisplayId { store.send(.displaySelected(display)) }
  }

  private static func connection(of machine: CodevisorMachine) -> (kind: String, address: String?) {
    if machine.isLocal { return ("Codevisor on this Mac", nil) }
    if machine.isCloud { return ("Codevisor Cloud", nil) }
    let url = machine.baseURL
    return ("Codevisor server", url.host().map { host in url.port.map { "\(host):\($0)" } ?? host })
  }
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
      if store.phase == .viewing, let notice = store.hostNotice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
      }
      ZStack {
        if let endpoint = store.endpoint {
          ScreenSharingNativeView(endpoint: endpoint, letterbox: theme.isSystem ? nil : theme.paneBackground)
        }
        if store.phase != .viewing {
          VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(
              store.phase == .reconnecting
                ? "Reconnecting to \(pane.connectionName)…" : "Connecting to \(pane.connectionName)…")
            if let notice = store.hostNotice { Text(notice).font(.callout).foregroundStyle(.secondary) }
          }
          .padding(24)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// The endpoint's video surface, with the fill around the remote display kept
/// on the app's surface color — themed panes use their own, and the system
/// theme (whose pane background defers to the window backdrop) gets the native
/// window background rather than black bars.
private struct ScreenSharingNativeView: NSViewRepresentable {
  let endpoint: ScreenSharingViewerEndpoint
  let letterbox: Color?
  func makeNSView(context: Context) -> NSView { endpoint.view }
  func updateNSView(_ nsView: NSView, context: Context) {
    endpoint.letterbox(letterbox.map(NSColor.init) ?? .windowBackgroundColor)
  }
}
