import SwiftUI
import CodevisorCore
import CodevisorUI

extension NewChatView {
  /// New Chat owns its target machine. An explicit project wins, followed
  /// by the last composer target. No application lifecycle or request
  /// routing reads this preference.
  var composerServerId: String {
    if let controller { return controller.project.serverId }
    if let composerMachineFallbackId { return composerMachineFallbackId }
    if let initialProjectTarget { return initialProjectTarget.serverId }
    if let remembered = environment.composerDefaults.lastNewWorkspaceServerId,
      environment.machines.allMachines.contains(where: { $0.id == remembered })
    {
      return remembered
    }
    return environment.defaultComposerServerId
  }

  var projects: [Project] {
    environment.projectList.fleetActiveProjects.filter {
      $0.serverId == composerServerId
    }
  }

  /// The draft machine's current route — direct or relay — so the
  /// composer notices a failover that leaves the machine set unchanged.
  var routeForDraftMachine: MachineRoute? {
    environment.machines.statusByMachineId[composerServerId]?.route
  }

  var setupIdentity: String {
    let target =
      initialProjectTarget.map {
        "\($0.serverId):\($0.projectId.uuidString)"
      } ?? "default"
    return "\(target):\(requiresInitialProjectResolution ? "resolving" : "ready")"
  }

  var harnessCatalogRevision: UInt64 {
    environment.harnessCatalogRevision(for: composerServerId)
  }

  /// A draft restored before machine discovery can still point at the cloud
  /// twin of a configured machine. Once the status probe links the two,
  /// move the draft to the configured identity while preserving the exact
  /// logical project when that machine has it.
  func canonicalProjectTarget(for controller: SessionController) -> Project? {
    let current = controller.project
    guard
      let canonicalServerId = environment.machines.canonicalComposerMachineId(
        for: current.serverId
      ),
      canonicalServerId != current.serverId
    else { return nil }
    if current.isRunTargetPlaceholder {
      return .runTargetPlaceholder(serverId: canonicalServerId)
    }
    return environment.projectList.fleetActiveProjects.first {
      $0.serverId == canonicalServerId && $0.id == current.id
    } ?? .runTargetPlaceholder(serverId: canonicalServerId)
  }

  @ViewBuilder
  var machineScopedBody: some View {
    if paneDraftId == nil, blocksComposerServerContent {
      ServerAvailabilityView(
        machineId: composerMachine.id,
        availability: composerServerAvailability,
        machineName: composerMachine.name,
        isLocal: composerMachine.isLocal,
        dataUpgradeProgress: composerMachine.isLocal
          ? environment.localServer?.dataUpgradeProgress
          : nil,
        appUpdateInProgress: environment.appUpdate.isUpdating,
        useLocalMachine: localFallbackMachine.map { local in
          { useLocalMachineForComposer(local) }
        }
      ) {
        Task {
          await environment.machines.retryMachine(composerMachine.id)
        }
      }
    } else if paneDraftId == nil {
      // An embedded draft pane must not override the workspace title.
      content.navigationTitle("New chat")
    } else {
      content
    }
  }

  private var composerMachine: CodevisorMachine {
    environment.machines.machine(for: composerServerId)
      ?? environment.machines.allMachines.first
      ?? CodevisorMachine.local
  }

  /// This Mac, when the page is aimed at a remote machine and the fleet
  /// still has a local server to fall back to.
  private var localFallbackMachine: CodevisorMachine? {
    guard !composerMachine.isLocal else { return nil }
    return environment.machines.machine(for: CodevisorMachine.local.id)
  }

  /// The escape hatch from a blocked remote target. Performs the same
  /// re-point as the composer's machine picker, but works while the
  /// composer is unmounted. The retained page draft may itself be aimed at
  /// the remote machine (the picker retargets drafts in place, and that is
  /// how a remote became the default), so it is re-pointed like the picker
  /// would; otherwise only the remembered machine changes. The page-local
  /// override then mounts the composer on this Mac.
  private func useLocalMachineForComposer(_ local: CodevisorMachine) {
    composerMachineFallbackId = local.id
    let draft =
      controller
      ?? store.draft(project: .runTargetPlaceholder(serverId: local.id))
    if draft.project.serverId == local.id {
      environment.composerDefaults.rememberNewWorkspaceServer(serverId: local.id)
    } else {
      selectTargetMachine(local, controller: draft)
    }
  }

  private var composerServerAvailability: ServerAvailability {
    environment.machines.availabilityByMachineId[composerServerId] ?? .ready
  }

  private var blocksComposerServerContent: Bool {
    if environment.appUpdate.isUpdating { return true }
    if composerMachine.isLocal,
      let progress = environment.localServer?.dataUpgradeProgress,
      progress.state == "running" || progress.state == "failed"
    {
      return true
    }
    if case .ready = composerServerAvailability { return false }
    return true
  }
}
