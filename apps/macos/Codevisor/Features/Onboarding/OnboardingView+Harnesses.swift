import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import os
import CodevisorUI

extension OnboardingView {
  // MARK: - Harnesses

  /// The account's harness fleet, exactly as Settings › Harnesses shows it
  /// afterwards. On a first Mac that is this machine's catalog; on another
  /// it is the fleet this Mac just joined — every harness lists each
  /// machine, so what will install here and what this Mac contributes are
  /// the same rows, not two explanations.
  var harnessesStep: some View {
    VStack(spacing: 20) {
      stepHeader(
        symbol: "terminal",
        title: "Choose your harnesses",
        subtitle: "Harnesses you turn on sync to every Mac signed in to your account."
      )

      switch detection {
      case .connecting:
        progress("Checking agents…")
      case .syncing:
        progress("Syncing your account…")
      case let .unreachable(message):
        VStack(spacing: 12) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Can't reach the Codevisor server").fontWeight(.medium)
              Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarn)
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
          Button {
            Task { await detectHarnesses() }
          } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
          }
        }
      case .loaded:
        fleetCard
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func progress(_ title: String) -> some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 20)
  }

  /// Settings › Harnesses, verbatim — the same `Form`, section, rows, and
  /// footer — sized to the step so it scrolls on its own inside the page.
  private var fleetCard: some View {
    Form {
      if HarnessFleet.settings(environment.configSync).isEmpty {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("No harnesses yet").fontWeight(.medium)
              Text("Add one to install it on this Mac. No restart needed.")
                .font(.callout).foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "terminal").foregroundStyle(.secondary)
          }
        }
      }
      HarnessGlobalSection(
        model: fleetModel,
        onAccounts: { fleetPresenter.showAccounts($0, startsSignIn: $1) },
        onSignIn: { fleetPresenter.showSignIn(machineId: $0, harnessId: $1, startsSignIn: $2) }
      ) { id, symbol in
        HarnessIcon(harnessId: id, fallbackSymbolName: symbol, size: 18)
      }
    }
    .settingsPaneFormStyle(theme)
    .frame(height: fleetListHeight)
  }

  /// Everything below the step header, so the list fills the page and the
  /// page itself never has to scroll behind it.
  private var fleetListHeight: CGFloat {
    max(280, viewportHeight - 64 - 190)
  }

  // MARK: - Detection

  /// Light refetch (no PATH re-resolve) when a lifecycle event invalidated
  /// the catalog — the seed and the new-chat picker follow installs live.
  func refreshHarnessList() async {
    guard detection == .loaded else { return }
    if let loaded = try? await environment.harnessService(for: CodevisorMachine.local.id).allHarnesses() {
      harnesses = loaded
      HarnessFleet.seed(from: harnesses, in: environment.configSync)
    }
  }

  /// Waits for the local server, loads this Mac's catalog with a short
  /// retry tail, then converges with the account's fleet before the list
  /// renders. Onboarding shows on first launch — exactly when the server
  /// is cold-starting — so querying immediately used to hit a closed port
  /// and misreport "No harnesses found".
  func detectHarnesses() async {
    detection = .connecting
    projectSetup.isLoadingRecommendations = true
    if !AppPreview.isRunning {
      // Joins the root view's in-flight server start (ensureRunning
      // dedups concurrent callers) instead of racing ahead of it.
      await environment.prepareMachine(CodevisorMachine.local.id)
    }
    // Safety net past the health wait: a handful of quick retries, not
    // one instantly-failing shot.
    var loaded: [ServerHarness]?
    for attempt in 0..<8 {
      loaded = try? await environment.harnessService(for: CodevisorMachine.local.id).allHarnesses()
      if loaded != nil { break }
      if attempt < 7 {
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
    guard let loaded else {
      projectSetup.isLoadingRecommendations = false
      detection = .unreachable(serverFailureMessage)
      return
    }
    harnesses = loaded
    await joinFleet()
    detection = .loaded
    // Suggest project folders from the user's most recent harness
    // sessions so the project step offers one-click choices.
    projectSetup.recommendations = await environment.recommendedProjectsWithFallback(
      serverId: CodevisorMachine.local.id
    )
    projectSetup.isLoadingRecommendations = false
  }

  /// Pulls the account's shared state from its reachable machines, then
  /// adds what this Mac has ready to the fleet — additively: a harness the
  /// fleet already knows keeps the preference authored elsewhere. Bounded
  /// so a machine that answers slowly can't hold the step; anything it
  /// missed lands on the next sweep and the list follows the replica.
  private func joinFleet() async {
    if !AppPreview.isRunning, environment.cloud.state.isSignedIn || !environment.cloud.hasCompletedBootstrap {
      detection = .syncing
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await pullFleet() }
        group.addTask { try? await Task.sleep(for: .seconds(20)) }
        await group.next()
        group.cancelAll()
      }
    }
    HarnessFleet.seed(from: harnesses, in: environment.configSync)
  }

  private func pullFleet() async {
    // A relaunch mid-flow resumes here while the persisted session is
    // still being validated; the roster is empty until that lands.
    while !environment.cloud.hasCompletedBootstrap, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard environment.cloud.state.isSignedIn else { return }
    await environment.cloud.refreshMachines()
    // Machines the account reports offline can't answer; probing them
    // only waits out a relay timeout.
    let offline = Set(environment.cloud.machines.filter { !$0.online }.map(\.deviceId))
    let ids = environment.machines.allMachines.map(\.id).filter { id in
      guard let device = CodevisorMachine.cloudDeviceId(forMachineId: id) else { return true }
      return !offline.contains(device)
    }
    await withTaskGroup(of: Void.self) { group in
      for id in ids {
        group.addTask { await environment.prepareMachine(id) }
      }
    }
    await environment.configSync.synchronizeAll()
  }

  private var serverFailureMessage: String {
    if case let .unavailable(message) = environment.localServer?.state {
      return message
    }
    return "The Codevisor server didn't respond. Try again, or check Settings → Machines."
  }
}
