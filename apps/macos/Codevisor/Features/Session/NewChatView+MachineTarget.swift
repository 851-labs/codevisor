import SwiftUI
import CodevisorCore
import CodevisorUI

extension NewChatView {
    /// New Chat owns its target machine. An explicit project wins, followed
    /// by the last composer target; the legacy selected machine is only a
    /// bootstrap fallback for installs that have not recorded a preference.
    var composerServerId: String {
        if let controller { return controller.project.serverId }
        if let preferred = environment.projectList.fleetActiveProjects.first(where: {
            $0.id == preferredProjectId
        }) {
            return preferred.serverId
        }
        if let remembered = environment.composerDefaults.lastNewWorkspaceServerId,
            environment.machines.allMachines.contains(where: { $0.id == remembered })
        {
            return remembered
        }
        return environment.machines.selectedMachineId
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
        "\(composerServerId):\(preferredProjectId?.uuidString ?? "default"):\(requiresInitialProjectResolution ? "resolving" : "ready")"
    }

    var harnessCatalogRevision: UInt64 {
        environment.harnessCatalogRevision(for: composerServerId)
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
                appUpdateInProgress: environment.appUpdate.isUpdating
            ) {
                Task {
                    if composerMachine.id == environment.machines.selectedMachineId {
                        await environment.machines.retrySelectedMachine()
                    } else {
                        await environment.machines.connectMachine(composerMachine.id)
                    }
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
            ?? environment.machines.selectedMachine
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
