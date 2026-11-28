import SwiftUI
import CodevisorCore
import CodevisorUI

struct PaneGroupContent: View {
  var group: PaneGroupModel
  @Environment(\.reusesChatPage) private var reusesChatPage
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    if let descriptor = group.state.selectedPane {
      if waitsForMachine(descriptor) {
        MachineWaitView()
      } else {
        PaneContentMount(group: group, paneId: descriptor.id)
          .id(identity(of: descriptor))
      }
    }
  }

  private func waitsForMachine(_ descriptor: PaneDescriptorState) -> Bool {
    descriptor.kind.needsLiveMachine && environment.machines.isAway(group.machineId(of: descriptor))
  }

  private func identity(of descriptor: PaneDescriptorState) -> String {
    if reusesChatPage, descriptor.kind == .chat { return descriptor.kind.rawValue }

    return "\(descriptor.id):\(descriptor.kind.rawValue)"
  }
}

private struct PaneContentMount: View {
  let group: PaneGroupModel
  let paneId: UUID
  @State private var canMount = false

  var body: some View {
    Group {
      if canMount || group.presentedPaneIDs.contains(paneId) {
        if let pane = group.selectedPane, pane.id == paneId {
          pane.makeView()
            .onAppear { group.paneContentDidMount(id: paneId) }
        }
      } else {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onChange(of: PaneMount(group: group, paneId: paneId)) { _, mount in
      if canMount { mount.group.paneContentDidMount(id: mount.paneId) }
    }
    .task(id: paneId) {
      guard !group.presentedPaneIDs.contains(paneId) else { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, group.state.selectedPaneId == paneId else { return }
      canMount = true
    }
  }
}

private struct PaneMount: Equatable {
  let group: PaneGroupModel
  let paneId: UUID

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.group === rhs.group && lhs.paneId == rhs.paneId
  }
}
