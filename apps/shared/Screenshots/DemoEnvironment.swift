#if DEBUG
  import CodevisorCore
  import Foundation

  enum DemoEnvironment {
    @MainActor
    static func make() -> AppEnvironment {
      let environment = AppEnvironment(
        configCache: ConfigOptionCache(store: InMemoryStore()),
        settings: settings(),
        appUpdate: appUpdate(),
        machineClientFactory: { DemoServerClient(machine: DemoModels.machine(forMachineId: $0.id)) }
      )
      environment.machines.cloudProvider = DemoCloudMachines()
      environment.updateCenter.now = { DemoWorld.now }
      seedMcpReadiness(environment)
      return environment
    }

    @MainActor
    static func connect(_ environment: AppEnvironment) async {
      await environment.machines.refreshStatus(for: CodevisorMachine.local.id)
      for machine in environment.machines.allMachines where !machine.isLocal {
        await environment.machines.refreshStatus(for: machine.id)
      }
      for machine in environment.machines.allMachines {
        await environment.navigationStore.refresh(
          machineId: machine.id, client: environment.machines.client(for: machine.id))
      }
      environment.markNavigationCurrentForPreview(machineIds: environment.machines.allMachines.map(\.id))
    }

    @MainActor
    static func seedNavigation(_ environment: AppEnvironment) {
      for project in DemoModels.projects {
        environment.navigationStore.enqueue(.upsertProject(project), machineId: project.serverId)
        environment.configCache.store(DemoServerRecords.capabilities, forServer: project.serverId)
      }
      for session in DemoModels.sessions {
        environment.navigationStore.enqueue(.upsertSession(session, workspaceId: nil), machineId: session.serverId)
      }
    }

    @MainActor
    private static func settings() -> AppSettingsModel {
      let settings = AppSettingsModel(store: InMemoryStore())
      settings.completeOnboarding(importExternalSessions: false)
      settings.setShareCrashReports(false)
      settings.setChatFinishedSoundPath(DemoWorld.chatFinishedSoundPath)
      settings.setActionRequiredSoundPath(DemoWorld.actionRequiredSoundPath)
      return settings
    }

    @MainActor
    private static func appUpdate() -> AppUpdateModel {
      let update = AppUpdateModel(currentVersion: DemoWorld.appVersion)
      update.checkHandler = {}
      update.reportAvailable(version: DemoWorld.latestAppVersion, releasePageURL: nil)
      return update
    }

    @MainActor
    static func seedHarnessFleet(_ environment: AppEnvironment) {
      for machine in DemoWorld.machines {
        environment.configSync.set(
          namespace: "harness-readiness", key: machine.serverId, value: DemoServerRecords.harnessReadiness(on: machine))
      }
      for agent in DemoWorld.harnessesOnEveryMachine {
        environment.configSync.set(
          namespace: "harnesses", key: agent.harnessId, value: DemoServerRecords.harnessSetting(agent))
      }
    }

    @MainActor
    private static func seedMcpReadiness(_ environment: AppEnvironment) {
      for machine in DemoWorld.machines {
        environment.configSync.set(
          namespace: "mcp-readiness", key: machine.serverId, value: DemoServerRecords.mcpReadiness)
      }
    }
  }

  @MainActor
  private final class DemoCloudMachines: CloudMachineProviding {
    let isCloudSignedIn = true
    let isCloudRosterVerified = true
    let cloudMachines = DemoWorld.machines.map {
      CloudMachine(
        deviceId: $0.deviceId, name: $0.name, icon: $0.icon, os: $0.os, publicKey: "demo", online: true,
        lastSeenAt: ISO8601DateFormatter().string(from: DemoWorld.now))
    }

    func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? { nil }
  }
#endif
