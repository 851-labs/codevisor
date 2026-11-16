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
  var onFocusChanged: ((Bool) -> Void)? { didSet { surface?.onFocusChanged = onFocusChanged } }
  var onFocus: (() -> Void)?
  private var mounts = Set<UUID>()
  private var seedDisplayId: String?
  private var recordedViewing = false
  private var soundAppliedTo: ObjectIdentifier?
  private var savedSettingsAppliedTo: ObjectIdentifier?
  private var clipboardAppliedTo: ObjectIdentifier?
  private let machineId: String
  private let connection: (kind: String, address: String?)
  private let surface: ScreenSharingDesktopSurface?
  private let workspace: ScreenSharingPaneWorkspace
  private var isOnScreen = false
  private var observation: ObserveToken?

  var connectionName: String { machineName }

  convenience init(context: PaneContext, descriptor: PaneDescriptorState, role: ScreenSharingViewerRole = .tab) {
    self.init(
      id: descriptor.id, machine: context.machine, role: role,
      workspace: ScreenSharingPaneWorkspace(context.workspaceId), preferences: descriptor.screenSharing ?? .init(),
      attaches: context.workspaceId != nil)
  }

  init(
    id: UUID = UUID(), machine: CodevisorMachine, role: ScreenSharingViewerRole, workspace: ScreenSharingPaneWorkspace,
    preferences: ScreenSharingPanePreferences, attaches: Bool = true
  ) {
    self.id = id
    self.role = role
    self.workspace = workspace
    seedDisplayId = preferences.preferredDisplayId
    machineName = machine.name
    machineId = machine.id
    isLocal = machine.isLocal
    connection = Self.connection(of: machine)
    surface = attaches ? Self.makeSurface(machine: machine, role: role, workspace: workspace) : nil
    store = surface.map { Self.makeStore(machine: machine, surface: $0) }
    guard let store else { return }
    surface?.onChange = { [weak store] in store?.send(.surfaceChanged($0)) }
    surface?.onKeyboardReturned = { [weak self] in self?.onFocus?() }
    if let snapshot = surface?.snapshot { store.send(.surfaceChanged(snapshot)) }
    observation = observe { [weak self] in self?.follow(store) }
  }

  private func follow(_ store: StoreOf<ScreenSharingViewer>) {
    if let endpoint = store.endpoint, let audio = endpoint.audio, soundAppliedTo != ObjectIdentifier(endpoint) {
      soundAppliedTo = ObjectIdentifier(endpoint)
      let saved = ScreenSharingMachinePreferences().sound(machineId: machineId)
      audio.apply(.init(enabled: saved.enabled, volume: saved.volume))
    }
    if let endpoint = store.endpoint, savedSettingsAppliedTo != ObjectIdentifier(endpoint) {
      savedSettingsAppliedTo = ObjectIdentifier(endpoint)
      endpoint.highDynamicRange = ScreenSharingMachinePreferences().highDynamicRange(machineId: machineId)
      endpoint.localShortcuts = savedKeyboard.localShortcuts
    }
    if let endpoint = store.endpoint, let clipboard = endpoint.clipboard {
      let sharing = clipboard.sharing
      let saved = ScreenSharingMachinePreferences().sharedClipboard(machineId: machineId)
      if clipboardAppliedTo != ObjectIdentifier(endpoint) {
        clipboardAppliedTo = ObjectIdentifier(endpoint)
        clipboard.sharing = saved
      } else if sharing != saved {
        ScreenSharingMachinePreferences().setSharedClipboard(sharing, machineId: machineId)
      }
    }
    let viewing = store.isLive
    if viewing, !recordedViewing {
      ScreenSharingMachinePreferences().setLastConnected(Date(), machineId: machineId)
    }
    recordedViewing = viewing
  }

  func makeView() -> AnyView { AnyView(ScreenSharingPaneView(pane: self)) }

  private static func makeSurface(
    machine: CodevisorMachine, role: ScreenSharingViewerRole, workspace: ScreenSharingPaneWorkspace
  ) -> ScreenSharingDesktopSurface? {
    guard !machine.isLocal else { return nil }

    return AppRuntime.shared.screenSharing?.surface(onMachine: machine.id, role: role, shownIn: { workspace.id })
  }

  private static func makeStore(
    machine: CodevisorMachine, surface: ScreenSharingDesktopSurface
  ) -> StoreOf<ScreenSharingViewer> {
    Store(initialState: ScreenSharingViewer.State(machineName: machine.name)) {
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
      preferredDisplayId: store?.selectedDisplayId ?? seedDisplayId,
      lastConnected: ScreenSharingMachinePreferences().lastConnected(machineId: machineId),
      sound: store?.endpoint?.audio.map { .init(enabled: $0.enabled, volume: $0.volume) })
    settings.dynamicResolutionNote = Self.dynamicResolutionNote(store?.endpoint)
    settings.switchesDisplayInSession = store?.switchesDisplayInSession == true
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
      store.endpoint?.localShortcuts = keyboard.localShortcuts
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
  func focus() { if surface?.videoHasKeyboardFocus != true { onFocus?() } }
  func visibilityChanged(_ visible: Bool) {}
  func applyPreferences(_ preferences: ScreenSharingPanePreferences) { seedDisplayId = preferences.preferredDisplayId }
  func willDelete() async { leave() }
  func detach() { leave() }

  func videoView() -> NSView? { surface?.videoView() }

  func letterbox(_ color: NSColor) { surface?.letterbox(color) }

  func openedByUser() {
    surface?.openedByUser()
  }

  func onScreenChanged(_ onScreen: Bool) {
    isOnScreen = onScreen
    surface?.setOnScreen(onScreen, seedDisplay: seedDisplayId)
    store?.send(onScreen ? .shown : .hidden)
  }

  func shown(inWorkspace workspaceId: UUID) {
    guard workspace.id != workspaceId else { return }

    workspace.id = workspaceId
    if isOnScreen { surface?.setOnScreen(true, seedDisplay: seedDisplayId) }
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
          failed(failure, store)
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

  private func failed(_ sentence: String, _ store: StoreOf<ScreenSharingViewer>) -> some View {
    ScreenSharingStatusView(content: .failure(sentence: sentence, action: store.failureAction), size: .pane) { _ in
      store.send(.retryButtonTapped)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .simultaneousGesture(
      TapGesture().onEnded {
        pane.onFocusChanged?(true)
        pane.focus()
      }
    )
  }

  private var unavailableReason: String {
    pane.isLocal
      ? "Codevisor doesn't show the desktop of the Mac it's running on."
      : "Open this pane in a workspace connected to a Mac."
  }

}
