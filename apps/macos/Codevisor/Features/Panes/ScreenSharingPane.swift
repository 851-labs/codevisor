import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ComposableArchitecture
import ScreenSharing
import SwiftUI

@MainActor
final class ScreenSharingPane: Pane {
  let id: UUID
  let kind: PaneKind = .screenSharing
  let store: StoreOf<ScreenSharingViewer>?
  let machineName: String
  let isLocal: Bool
  let role: ScreenSharingViewerRole
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)? { didSet { store?.endpoint?.onFocusChanged = onFocusChanged } }
  var onFocus: (() -> Void)?
  var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)?
  private var mounts = Set<UUID>()
  private var persistedRevision = 0
  private var persistedResolutionRevision = 0
  private var recordedViewing = false
  private var soundAppliedTo: ObjectIdentifier?
  private var savedSettingsAppliedTo: ObjectIdentifier?
  private var clipboardAppliedTo: ObjectIdentifier?
  private let machineId: String
  private let connection: (kind: String, address: String?)
  private let surface: ScreenSharingDesktopSurface?
  private var observation: ObserveToken?

  var connectionName: String { machineName }

  init(context: PaneContext, descriptor: PaneDescriptorState, role: ScreenSharingViewerRole = .tab) {
    id = descriptor.id
    self.role = role
    machineName = context.machine.name
    machineId = context.machine.id
    isLocal = context.machine.isLocal
    connection = Self.connection(of: context.machine)
    surface = Self.makeSurface(context: context, role: role)
    store = surface.map { Self.makeStore(context: context, descriptor: descriptor, surface: $0) }
    guard let store else { return }
    surface?.onChange = { [weak store] in store?.send(.surfaceChanged($0)) }
    if let snapshot = surface?.snapshot { store.send(.surfaceChanged(snapshot)) }
    observation = observe { [weak self] in
      guard let self else { return }
      store.endpoint?.onFocusChanged = self.onFocusChanged
      store.endpoint?.onKeyboardReturned = { [weak self] in self?.onFocus?() }
      if let endpoint = store.endpoint, let audio = endpoint.audio, self.soundAppliedTo != ObjectIdentifier(endpoint) {
        self.soundAppliedTo = ObjectIdentifier(endpoint)
        let saved = ScreenSharingMachinePreferences().sound(machineId: self.machineId)
        audio.apply(.init(enabled: saved.enabled, volume: saved.volume))
      }
      if let endpoint = store.endpoint, self.savedSettingsAppliedTo != ObjectIdentifier(endpoint) {
        self.savedSettingsAppliedTo = ObjectIdentifier(endpoint)
        endpoint.highDynamicRange = ScreenSharingMachinePreferences().highDynamicRange(machineId: self.machineId)
        endpoint.localShortcuts = self.savedKeyboard.localShortcuts
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
      let viewing = store.isLive
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

  private static func makeSurface(context: PaneContext, role: ScreenSharingViewerRole) -> ScreenSharingDesktopSurface? {
    guard context.workspaceId != nil, !context.machine.isLocal else { return nil }

    return AppRuntime.shared.screenSharing?.surface(
      onMachine: context.machine.id, role: role, inWorkspace: context.workspaceId)
  }

  private static func makeStore(
    context: PaneContext, descriptor: PaneDescriptorState, surface: ScreenSharingDesktopSurface
  ) -> StoreOf<ScreenSharingViewer> {
    let state = ScreenSharingViewer.State(
      machineName: context.machine.name, preferences: descriptor.screenSharing ?? .init(),
      dynamicResolution: ScreenSharingMachinePreferences().dynamicResolution(machineId: context.machine.id))
    return Store(initialState: state) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingSurfaceClient.self] = .live(surface)
    }
  }

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
    settings.dynamicResolutionMirrorsDisplay = store?.endpoint?.resizeMirrorsHostDisplay ?? false
    if store?.endpoint?.supportsControl != false {
      settings.keyboard = savedKeyboard
      settings.screenshotShortcuts = ScreenSharingLocalShortcutGroup.screenshots.shortcutNames
    }
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
    if let keyboard = changes.keyboard {
      ScreenSharingMachinePreferences().setScreenshotsStayLocal(keyboard.screenshotsStayLocal, machineId: machineId)
      (store.endpoint ?? store.mirror)?.localShortcuts = keyboard.localShortcuts
    }
    if let display = changes.preferredDisplayId { store.send(.displaySelected(display)) }
  }

  private var savedKeyboard: ScreenSharingMachineSettings.Keyboard {
    .init(screenshotsStayLocal: ScreenSharingMachinePreferences().screenshotsStayLocal(machineId: machineId))
  }

  private static func connection(of machine: CodevisorMachine) -> (kind: String, address: String?) {
    if machine.isLocal { return ("Codevisor on this Mac", nil) }
    if machine.isCloud { return ("Codevisor Cloud", nil) }
    let url = machine.baseURL
    return ("Codevisor server", url.host().map { host in url.port.map { "\(host):\($0)" } ?? host })
  }
  func focus() { if store?.endpoint?.videoHasKeyboardFocus != true { onFocus?() } }
  func visibilityChanged(_ visible: Bool) {}
  func applyPreferences(_ preferences: ScreenSharingPanePreferences) { store?.send(.preferencesSynced(preferences)) }
  func willDelete() async { leave() }
  func detach() { leave() }

  func openedByUser() {
    surface?.openedByUser()
  }

  func onScreenChanged(_ onScreen: Bool) {
    surface?.setOnScreen(onScreen, preferringDisplay: store?.preferences.preferredDisplayId)
    store?.send(onScreen ? .shown : .hidden)
  }

  private func leave() {
    store?.send(.hidden)
    surface?.detach()
  }
}

private struct ScreenSharingPaneView: View {
  let pane: ScreenSharingPane

  var body: some View {
    ZStack {
      if let store = pane.store {
        if let failure = store.failure {
          ScreenSharingFailureView(pane: pane, message: failure) { store.send(.retryButtonTapped) }
        } else if store.mirror != nil {
          elsewhere(store)
        } else {
          ScreenSharingConnectionView(pane: pane, store: store)
        }
      } else {
        ContentUnavailableView(
          "Screen Sharing unavailable", systemImage: "display", description: Text(unavailableReason))
      }
    }
    .background { ScreenSharingOnScreen { pane.onScreenChanged($0) } }
  }

  private var unavailableReason: String {
    pane.isLocal
      ? "Codevisor doesn't show the desktop of the Mac it's running on."
      : "Open this pane in a workspace connected to a Mac."
  }

  private func elsewhere(_ store: StoreOf<ScreenSharingViewer>) -> some View {
    ScreenSharingMirrorPane(
      endpoint: store.mirror, connectionName: pane.connectionName,
      onTakeControl: pane.role == .watcher ? nil : { store.send(.showHereTapped) }
    )
    .simultaneousGesture(TapGesture().onEnded { pane.onFocusChanged?(true) })
  }
}
