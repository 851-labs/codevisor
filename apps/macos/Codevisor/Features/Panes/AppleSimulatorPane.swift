import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SimulatorPane
import SwiftUI

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
  var canFocusChooser: () -> Bool = { true } {
    didSet { model?.canFocusChooser = canFocusChooser }
  }

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    model = Self.makeModel(context: context, descriptor: descriptor)
  }

  private static func makeModel(context: PaneContext, descriptor: PaneDescriptorState) -> SimulatorPaneModel? {
    guard context.workspaceId != nil else { return nil }

    let client = context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
    return SimulatorPaneModel(
      client: client, preferences: descriptor.simulator, machineId: context.machine.id,
      streams: streams(on: context.machine))
  }

  private static func streams(on machine: CodevisorMachine) -> SimulatorStreamSource {
    let machineId = machine.id
    return SimulatorStreamSource(
      machineName: machine.name,
      connection: { target in
        AppRuntime.shared.screenSharing?.targetConnection(onMachine: machineId, target: target)
      },
      end: { AppRuntime.shared.screenSharing?.endTargetConnection(onMachine: machineId, target: $0) })
  }

  func makeView() -> AnyView { AnyView(AppleSimulatorPaneView(pane: self)) }
  func focus() { model?.focusChooser() }
  func visibilityChanged(_ visible: Bool) {}
  func onScreenChanged(_ onScreen: Bool) { onScreen ? model?.appeared() : model?.disappeared() }
  func applyPreferences(_ preferences: SimulatorPanePreferences) { model?.applyPreferences(preferences) }
  func willDelete() async { model?.closed() }
  func detach() { model?.closed() }

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

  var body: some View {
    Group {
      if let model = pane.model {
        SimulatorPaneView(model: model, reportsAppearance: false) { data, name in
          AppleSimulatorPane.saveScreenshot(data, deviceName: name)
        }
      } else {
        ContentUnavailableView(
          "Simulator unavailable", systemImage: "iphone",
          description: Text("Open this pane in a workspace connected to a Mac with Xcode."))
      }
    }
    .background { ScreenSharingOnScreen { pane.onScreenChanged($0) } }
    .simultaneousGesture(
      TapGesture().onEnded {
        pane.onFocusChanged?(true)
        if pane.model?.device == nil { pane.focus() }
      })
  }
}
