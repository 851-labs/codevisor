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
  private var soundAppliedTo: ObjectIdentifier?
  private var hdrAppliedTo: ObjectIdentifier?
  private var clipboardAppliedTo: ObjectIdentifier?
  private let machineId: String
  private let connection: (kind: String, address: String?)
  private var observation: ObserveToken?

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
        $0[ScreenSharingViewerBackend.self] = .native(
          client: client, workspaceId: workspaceId, paneId: descriptor.id, machineId: context.machine.id,
          tunnelMedia: context.openTunnelMedia)
      }
    }
    guard let store else { return }
    observation = observe { [weak self] in
      guard let self else { return }
      store.endpoint?.onFocusChanged = self.onFocusChanged
      store.endpoint?.onKeyboardReturned = { [weak self] in self?.onFocus?() }
      if let endpoint = store.endpoint, let audio = endpoint.audio, self.soundAppliedTo != ObjectIdentifier(endpoint) {
        self.soundAppliedTo = ObjectIdentifier(endpoint)
        let saved = ScreenSharingMachinePreferences().sound(machineId: self.machineId)
        audio.apply(.init(enabled: saved.enabled, volume: saved.volume))
      }
      if let endpoint = store.endpoint, self.hdrAppliedTo != ObjectIdentifier(endpoint) {
        self.hdrAppliedTo = ObjectIdentifier(endpoint)
        endpoint.highDynamicRange = ScreenSharingMachinePreferences().highDynamicRange(machineId: self.machineId)
      }
      if let endpoint = store.endpoint, let clipboard = endpoint.clipboard {
        let sharing = clipboard.sharing
        let saved = ScreenSharingMachinePreferences().sharedClipboard(machineId: self.machineId)
        if self.clipboardAppliedTo != ObjectIdentifier(endpoint) {
          self.clipboardAppliedTo = ObjectIdentifier(endpoint)
          clipboard.sharing = saved
        } else if sharing != saved {
          ScreenSharingMachinePreferences().setSharedClipboard(sharing, machineId: self.machineId)
        }
      }
      let viewing = store.phase == .viewing
      if viewing, !self.recordedViewing {
        ScreenSharingMachinePreferences().setLastConnected(Date(), machineId: self.machineId)
      }
      self.recordedViewing = viewing
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
    if store?.endpoint?.supportsHighDynamicRange != false {
      settings.highDynamicRange = ScreenSharingMachinePreferences().highDynamicRange(machineId: machineId)
      settings.highDynamicRangeNote = store?.endpoint?.highDynamicRangeNote
    }
    return settings
  }

  static func dynamicResolutionNote(_ endpoint: ScreenSharingViewerEndpoint?) -> String? {
    guard let endpoint else { return nil }
    if !endpoint.supportsDynamicResolution || endpoint.resolutionAvailability.available == false {
      return "This machine can't change its resolution over this connection."
    }
    return nil
  }

  func applyMachineSettings(_ changes: ScreenSharingMachineSettingsChanges) {
    guard let store else { return }
    if let enabled = changes.dynamicResolution, enabled != store.dynamicResolution {
      store.send(.dynamicResolutionToggled)
    }
    if let enabled = changes.highDynamicRange {
      ScreenSharingMachinePreferences().setHighDynamicRange(enabled, machineId: machineId)
      store.endpoint?.highDynamicRange = enabled
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
  func focus() { if store?.endpoint?.videoHasKeyboardFocus != true { onFocus?() } }
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
    DispatchQueue.main.async { [weak self] in
      guard let self, self.mounts.isEmpty else { return }
      self.store?.send(.paneDisappeared)
    }
  }
}

private struct ScreenSharingPaneView: View {
  let pane: ScreenSharingPane
  @State private var mount = UUID()

  var body: some View {
    Group {
      if let store = pane.store {
        if store.phase == .failed {
          failure(store)
        } else if store.phase == .elsewhere {
          elsewhere(store)
        } else {
          connection(store)
        }
      } else {
        ContentUnavailableView(
          "Screen Sharing unavailable", systemImage: "display",
          description: Text("Open this pane in a workspace connected to a Mac."))
      }
    }
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

  private func elsewhere(_ store: StoreOf<ScreenSharingViewer>) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
      Text("\(pane.connectionName) is showing in another pane.").foregroundStyle(.secondary)
      Button("Show Here") { store.send(.showHereTapped) }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .simultaneousGesture(TapGesture().onEnded { pane.onFocusChanged?(true) })
  }

  private func connection(_ store: StoreOf<ScreenSharingViewer>) -> some View {
    VStack(spacing: 0) {
      if store.phase == .viewing, let message = store.lease?.message {
        HStack {
          Text(message).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if store.interactionMode == .control, store.lease?.phase == .viewing {
            Button("Request Control") { store.send(.interactionModeChanged(.control)) }.controlSize(.small)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
          ScreenSharingNativeView(endpoint: endpoint)
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

private struct ScreenSharingNativeView: NSViewRepresentable {
  let endpoint: ScreenSharingViewerEndpoint

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    let video = endpoint.view
    if video.superview !== container {
      container.subviews.forEach { $0.removeFromSuperview() }
      video.removeFromSuperview()
      video.frame = container.bounds
      video.autoresizingMask = [.width, .height]
      container.addSubview(video)
    }
    endpoint.letterbox(.windowBackgroundColor)
  }

  static func dismantleNSView(_ container: NSView, coordinator: ()) {
    container.subviews.forEach { $0.removeFromSuperview() }
  }
}
