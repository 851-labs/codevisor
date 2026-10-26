import SwiftUI
import CodevisorCore
import CodevisorUI

extension NewChatView {
  var composerServerId: String {
    if let controller { return controller.project.serverId }
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

  var setupIdentity: String {
    let target =
      initialProjectTarget.map {
        "\($0.serverId):\($0.projectId?.uuidString ?? "machine")"
      } ?? "default"
    return "\(target):\(requiresInitialProjectResolution ? "resolving" : "ready")"
  }

  var harnessCatalogRevision: UInt64 {
    environment.harnessCatalogRevision(for: composerServerId)
  }

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
        startupProgress: composerMachine.isLocal ? environment.localServer?.startupProgress : nil,
        appUpdateInProgress: environment.appUpdate.isUpdating,
        restart: composerMachine.isLocal ? { AppRelauncher.relaunch() } : nil
      )
    } else if paneDraftId == nil {
      content.navigationTitle("New chat")
    } else {
      content
    }
  }

  func refreshComposerTarget() async {
    guard composerServerAvailability == .ready else { return }
    let serverId = composerServerId
    let client = environment.machines.client(for: serverId)
    controller?.adoptServerClient(client, forServer: serverId)
    async let projects = environment.projectList.refreshFromServer(
      serverId: serverId, client: client
    )
    await controller?.prepare()
    _ = await projects
    guard !Task.isCancelled else { return }
    if requiresInitialProjectResolution {
      onInitialProjectResolutionCompleted?()
    }
  }

  struct PreparationIdentity: Equatable {
    let serverId: String
    let availability: ServerAvailability
  }

  var composerPreparationIdentity: PreparationIdentity {
    PreparationIdentity(serverId: composerServerId, availability: composerServerAvailability)
  }

  private var composerMachine: CodevisorMachine {
    environment.machines.machine(for: composerServerId)
      ?? environment.machines.allMachines.first
      ?? CodevisorMachine.local
  }

  var composerServerAvailability: ServerAvailability {
    environment.machines.availability(for: composerServerId)
  }

  private var blocksComposerServerContent: Bool {
    environment.appUpdate.isUpdating
  }

  func relocateWhenEphemeralMachineIsReady(_ controller: SessionController) {
    controller.onEphemeralMachineReady = { [weak controller, weak store = store] previous, relocated, project in
      EphemeralSessionRelocation.relocate(
        previous,
        to: relocated,
        project: project,
        projectList: environment.projectList,
        workspaces: environment.workspaces
      )
      guard let controller, let store else { return }
      controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
        projectList?.setAgentSessionId(agentSessionId, for: relocated.id, serverId: relocated.serverId)
      }
      store.reregister(controller, from: previous, to: relocated)
      store.selectChat(relocated)
      selection = .session(serverId: relocated.serverId, id: relocated.id)
    }
  }
}
