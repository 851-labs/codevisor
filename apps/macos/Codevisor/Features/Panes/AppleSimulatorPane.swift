import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SimulatorPane
import SwiftUI

/// An Apple simulator on the workspace's Mac (the shared SimulatorPane view and model).
@MainActor
final class AppleSimulatorPane: Pane {
  let id: UUID
  let kind: PaneKind = .simulator
  let model: SimulatorPaneModel?
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var onPreferencesChanged: ((SimulatorPanePreferences) -> Void)? {
    didSet { model?.onPreferencesChanged = onPreferencesChanged }
  }
  /// Whether the pane is still the focused group's selected tab, for a chooser that mounts late.
  var canFocusChooser: () -> Bool = { true } {
    didSet { model?.canFocusChooser = canFocusChooser }
  }
  private var mounts = Set<UUID>()

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    model = context.workspaceId.map { workspaceId in
      let client = context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
      let tunnel = context.openTunnelRoute
      let paneId = descriptor.id
      return SimulatorPaneModel(
        client: client, preferences: descriptor.simulator, workspaceId: workspaceId, paneId: paneId,
        openTunnel: tunnel)
    }
  }

  func makeView() -> AnyView { AnyView(AppleSimulatorPaneView(pane: self)) }
  func focus() { model?.focusChooser() }
  func visibilityChanged(_ visible: Bool) { visible ? model?.appeared() : model?.disappeared() }
  func applyPreferences(_ preferences: SimulatorPanePreferences) { model?.applyPreferences(preferences) }
  func willDelete() async { model?.closed() }
  func detach() { model?.closed() }

  func mounted(_ token: UUID) {
    mounts.insert(token)
    model?.appeared()
  }

  func unmounted(_ token: UUID) {
    mounts.remove(token)
    // SwiftUI reparents carried panes within one update; only a real navigation-away has no
    // replacement mount.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.mounts.isEmpty else { return }
      self.model?.disappeared()
    }
  }

  /// Saves a screenshot to the Desktop, as Simulator does, and shows it in Finder.
  static func saveScreenshot(_ data: Data, deviceName: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let name = "Simulator Screenshot - \(deviceName) - \(formatter.string(from: Date())).png"
      .replacingOccurrences(of: "/", with: "-")
    let desktop =
      FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    let url = desktop.appendingPathComponent(name)
    do {
      try data.write(to: url, options: .atomic)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      NSSound.beep()
    }
  }
}

private struct AppleSimulatorPaneView: View {
  let pane: AppleSimulatorPane
  @Environment(\.theme) private var theme
  @State private var mount = UUID()

  var body: some View {
    Group {
      if let model = pane.model {
        SimulatorPaneView(model: model) { data, name in AppleSimulatorPane.saveScreenshot(data, deviceName: name) }
      } else {
        ContentUnavailableView(
          "Simulator unavailable", systemImage: "iphone",
          description: Text("Open this pane in a workspace connected to a Mac with Xcode."))
      }
    }
    .background(theme.paneBackground)
    .onAppear { pane.mounted(mount) }
    .onDisappear { pane.unmounted(mount) }
    .simultaneousGesture(
      TapGesture().onEnded {
        pane.onFocusChanged?(true)
        // The chooser has no editor to take a click, so whitespace clicks focus its search field.
        if pane.model?.device == nil { pane.focus() }
      })
  }
}
