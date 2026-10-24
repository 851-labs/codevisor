#if DEBUG
  import CodevisorCore
  import Foundation

  nonisolated struct DemoServerClient: CodevisorServerClienting {
    let machine: DemoWorld.Machine

    func info() async throws -> ServerInfo {
      ServerInfo(
        id: machine.serverId, name: machine.name, kind: "codevisor", version: DemoWorld.appVersion,
        platform: machine.os, bindHost: "127.0.0.1", cloudDeviceId: machine.deviceId)
    }

    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
      DemoServerRecords.serverUpdate(on: machine)
    }

    func listMcpServers() async throws -> [ServerMcpServer] { DemoServerRecords.mcpServers(on: machine) }

    func toolIcon(_ request: ServerToolIconRequest) async throws -> Data {
      guard case .mcpServer(let id, _, _) = request, let icon = DemoServerRecords.mcpIcon(serverId: id)
      else { throw unavailable }
      return icon
    }

    func listHarnessAccounts(harnessId: String) async throws -> [ServerHarnessAccount] {
      DemoServerRecords.accounts(harnessId: harnessId)
    }

    func sharedHarnessAccount(
      harnessId: String, request: ServerSharedHarnessAccountRequest
    ) async throws -> ServerSharedHarnessAccountResponse {
      guard request.action == "list" else { throw unavailable }
      return DemoServerRecords.sharedAccounts(harnessId: harnessId)
    }

    func listHarnesses() async throws -> [ServerHarness] { DemoServerRecords.harnesses(on: machine) }
    func listHarnessesWithLifecycle() async throws -> [ServerHarness] { try await listHarnesses() }

    func browserExtensionArchive() async throws -> URL {
      let archive = FileManager.default.temporaryDirectory.appendingPathComponent("Codevisor Chrome Extension.zip")
      FileManager.default.createFile(atPath: archive.path, contents: Data())
      return archive
    }

    func browserExtensionIcon() async throws -> URL {
      guard let icon = DemoWorld.repoFile("packages/automation/resources/browser-extension/icons/128.png")
      else { throw unavailable }
      return icon
    }

    func machineStats() async throws -> ServerMachineStats { DemoServerRecords.machineStats(on: machine) }
    func sessionUsageLimits(id: UUID) async throws -> ServerHarnessUsageLimits { DemoServerRecords.usageLimits }
    func sessionContext(id: UUID) async throws -> ServerSessionContext? { DemoServerRecords.sessionContext }

    func simulators() async throws -> ServerSimulatorList { DemoServerRecords.simulators }
    func simulatorSettings(udid: String) async throws -> ServerSimulatorSettings {
      DemoServerRecords.simulatorSettings
    }

    func listProjects() async throws -> [ServerProject] { [] }
    func listSessions() async throws -> [ServerSession] { [] }
    func navigationSnapshot() async throws -> ServerNavigationSnapshot {
      DemoServerRecords.navigationSnapshot(on: machine)
    }
    func health() async throws -> ServerHealth {
      ServerHealth(ok: true, version: DemoWorld.appVersion, database: "ready")
    }

    func capabilities(cwd: String) async throws -> ServerCapabilities {
      ServerCapabilities(harnesses: DemoServerRecords.capabilities)
    }

    func upsertProject(_ project: Project) async throws -> ServerProject { throw unavailable }
    func deleteProject(id: UUID) async throws { throw unavailable }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession { throw unavailable }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { throw unavailable }
    func deleteSession(id: UUID) async throws { throw unavailable }
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted { throw unavailable }
    func cancelSession(id: UUID) async throws { throw unavailable }
    func setSessionMode(id: UUID, modeId: String) async throws { throw unavailable }
    func setSessionConfig(id: UUID, configId: String, value: String) async throws { throw unavailable }
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
      AsyncThrowingStream { _ in }
    }

    private var unavailable: CodevisorServerClientError { .invalidResponse }
  }
#endif
