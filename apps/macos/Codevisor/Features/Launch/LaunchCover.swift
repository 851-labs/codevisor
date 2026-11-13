import CodevisorCore
import SwiftUI

struct LaunchCover<Content: View>: View {
  let runtime: AppRuntime
  @ViewBuilder let content: () -> Content
  @State private var gate = LaunchGate()
  @State private var startIsSlow = false
  @State private var upgrades = LaunchUpgradeLog()

  var body: some View {
    let phase = gate.phase(for: snapshot)
    ZStack {
      content()
        .opacity(phase == .ready ? 1 : 0)
        .accessibilityHidden(phase != .ready)
        .toolbar(removing: phase == .ready ? nil : .title)
        .environment(\.appIsCovered, phase != .ready)
      if phase != .ready {
        LaunchScreen(phase: phase, upgrades: upgrades, actions: actions)
          .transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.35), value: phase == .ready)
    .onChange(of: phase, initial: true) { _, phase in settle(on: phase) }
    .onChange(of: snapshot.dataUpgrade) { _, progress in upgrades.note(progress) }
    .task(id: phase == .starting) { await watchForSlowStart(isStarting: phase == .starting) }
  }

  private var snapshot: LaunchSnapshot {
    let environment = runtime.environment
    let localServer = environment?.localServer
    return LaunchSnapshot(
      localDataFailure: runtime.startupError,
      hasLocalData: environment != nil,
      serverState: localServer?.state,
      dataUpgrade: localServer?.dataUpgradeProgress,
      availability: environment?.machines.availability(for: CodevisorMachine.local.id) ?? .waiting(.connecting),
      isWaitingForGit: environment?.machines.isWaitingForGit(on: CodevisorMachine.local.id) ?? false,
      startIsSlow: startIsSlow
    )
  }

  private var actions: LaunchActions {
    LaunchActions(
      tryAgain: tryAgain,
      continueAnyway: { gate.continueAnyway(past: $0) },
      showDataFolder: LaunchActions.showDataFolder
    )
  }

  private func settle(on phase: LaunchPhase) {
    gate.note(phase)
    if phase == .ready { upgrades.clear() }
  }

  private func tryAgain(after failure: LaunchFailure) {
    guard failure.stage == .localData else {
      AppRelauncher.relaunch()
      return
    }
    runtime.retry()
  }

  private func watchForSlowStart(isStarting: Bool) async {
    guard isStarting, !startIsSlow else { return }

    try? await Task.sleep(for: launchSlowStartThreshold)
    guard !Task.isCancelled else { return }
    startIsSlow = true
  }
}

private let launchSlowStartThreshold: Duration = .seconds(20)
