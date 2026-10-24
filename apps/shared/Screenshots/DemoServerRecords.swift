#if DEBUG
  import ACPKit
  import CodevisorCore
  import Foundation

  nonisolated enum DemoServerRecords {
    private struct BuiltInTool {
      let kind: String
      let name: String
      let toolCount: Int
    }

    private static let builtInTools = [
      BuiltInTool(kind: "browserUse", name: "Browser Use", toolCount: 84),
      BuiltInTool(kind: "computerUse", name: "Computer Use", toolCount: 21),
    ]

    private static let fixtureDate = ISO8601DateFormatter().string(from: DemoWorld.now)

    static func mcpServers(on machine: DemoWorld.Machine) -> [ServerMcpServer] {
      decode(builtInTools.map { builtInServer($0, on: machine) } + DemoWorld.mcpServers.map(mcpServer))
    }

    static let mcpReadiness: JSONValue = decode([
      "servers": builtInTools.map { readyServer($0.name, toolCount: $0.toolCount) }
        + DemoWorld.mcpServers.map { readyServer($0.name, toolCount: $0.toolCount) }
    ])

    static func mcpIcon(serverId: String) -> Data? {
      let server = DemoWorld.mcpServers.first { mcpServerId($0) == serverId }
      return server?.iconAsset.flatMap(DemoWorld.assetData)
    }

    static func accounts(harnessId: String) -> [ServerHarnessAccount] {
      decode(DemoWorld.accounts.map { account($0, harnessId: harnessId) })
    }

    static func sharedAccounts(harnessId: String) -> ServerSharedHarnessAccountResponse {
      decode(["accounts": DemoWorld.accounts.map { account($0, harnessId: harnessId) }])
    }

    static func harnessReadiness(on machine: DemoWorld.Machine) -> JSONValue {
      let installed = DemoWorld.installedAgents.filter { $0.machine.deviceId == machine.deviceId }
      return decode([
        "harnesses": installed.map { agent in
          [
            "id": agent.harnessId, "state": "ready", "installed": true, "version": agent.version, "name": agent.name,
            "symbolName": HarnessRegistry.descriptor(for: agent.harnessId).symbolName,
          ] as [String: Any]
        }
      ])
    }

    static func harnessSetting(_ agent: DemoWorld.InstalledAgent) -> JSONValue {
      decode([
        "enabled": true, "installed": true, "name": agent.name,
        "symbolName": HarnessRegistry.descriptor(for: agent.harnessId).symbolName,
      ])
    }

    static func harnesses(on machine: DemoWorld.Machine) -> [ServerHarness] {
      DemoWorld.installedAgents.filter { $0.machine.deviceId == machine.deviceId }.map(harness)
    }

    static let claudeCode = harness(
      DemoWorld.InstalledAgent(machine: DemoWorld.thisMac, harnessId: "claude-code", name: "Claude Code", version: ""))

    static let capabilities = [
      ServerHarnessCapability(
        harness: claudeCode, modes: nil,
        configOptions: [
          SessionConfigOption(
            id: "model", name: "Model", category: "model", currentValue: DemoWorld.featuredModel.id,
            options: [SessionConfigSelectOption(value: DemoWorld.featuredModel.id, name: DemoWorld.featuredModel.name)]
          )
        ])
    ]

    static func serverUpdate(on machine: DemoWorld.Machine) -> ServerUpdateInfo {
      let isBehind = DemoWorld.machinesWithServerUpdate.contains(machine.deviceId)
      return ServerUpdateInfo(
        currentVersion: DemoWorld.appVersion,
        latestVersion: isBehind ? DemoWorld.latestAppVersion : DemoWorld.appVersion,
        updateAvailable: isBehind, channel: "stable", checkedAt: fixtureDate, migrationState: "idle")
    }

    static let simulators: ServerSimulatorList = decode([
      "devices": [
        [
          "udid": DemoWorld.simulator.udid, "name": DemoWorld.simulator.name, "state": "Booted",
          "runtime": [
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "name": DemoWorld.simulator.runtime,
            "platform": "iOS", "version": DemoWorld.simulator.runtimeVersion,
          ],
          "deviceType": [
            "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": DemoWorld.simulator.name,
            "productFamily": "iPhone",
          ],
        ]
      ],
      "deviceTypes": [], "runtimes": [],
    ])

    static let simulatorSettings = ServerSimulatorSettings(
      appearance: "dark", increaseContrast: true, reduceMotion: false, showBorders: false, reduceTransparency: false,
      voiceOver: false, location: "none", audioOutput: ServerSimulatorSettings.systemAudioRoute)

    private static func mcpServerId(_ server: DemoWorld.McpServer) -> String { server.name.lowercased() }

    private static func mcpServer(_ server: DemoWorld.McpServer) -> [String: Any] {
      [
        "id": mcpServerId(server), "name": server.name, "transport": "http", "url": server.url, "args": [],
        "enabled": true, "authType": "oauth", "connectionState": "connected", "toolCount": server.toolCount,
        "createdAt": fixtureDate, "updatedAt": fixtureDate,
      ]
    }

    private static func builtInServer(_ tool: BuiltInTool, on machine: DemoWorld.Machine) -> [String: Any] {
      [
        "id": "\(tool.kind)-\(machine.deviceId)", "name": tool.name, "kind": tool.kind, "canEdit": false,
        "canRemove": false, "transport": "stdio", "args": [], "enabled": true, "authType": "none",
        "connectionState": "connected", "toolCount": tool.toolCount, "createdAt": fixtureDate, "updatedAt": fixtureDate,
      ]
    }

    private static func readyServer(_ name: String, toolCount: Int) -> [String: Any] {
      ["name": name, "state": "ready", "toolCount": toolCount]
    }

    private static func account(_ account: DemoWorld.Account, harnessId: String) -> [String: Any] {
      [
        "id": account.email, "harnessId": harnessId, "profileKind": "default", "label": account.email,
        "email": account.email, "authState": "authenticated", "isActive": account.isActive,
        "selectionScope": account.isActive ? "shared" : "machine", "canLogin": true, "canLogout": false,
      ]
    }

    private static func harness(_ agent: DemoWorld.InstalledAgent) -> ServerHarness {
      let descriptor = HarnessRegistry.descriptor(for: agent.harnessId)
      return ServerHarness(
        id: agent.harnessId, name: agent.name, symbolName: descriptor.symbolName, source: "registry",
        launchKind: "executable", enabled: true,
        readiness: ServerHarnessReadiness(state: "ready", version: agent.version),
        auth: agent.harnessId == "claude-code" ? claudeAuth : nil,
        updateInfo: ServerHarnessUpdateInfo(
          installedVersion: agent.version, latestVersion: agent.latestVersion ?? agent.version,
          updateAvailable: agent.latestVersion != nil))
    }

    private static let claudeAuth: ServerHarnessAuth = decode([
      "state": "authenticated", "accounts": [], "supportsMultipleAccounts": true,
      "loginMethods": [
        ["id": "claude", "name": "Claude account", "kind": "oauth"],
        ["id": "console", "name": "Anthropic Console", "kind": "oauth"],
      ],
    ])

    static func machineStats(on machine: DemoWorld.Machine) -> ServerMachineStats {
      let hardware = machine.hardware
      var stats: [String: Any] = [
        "sampledAt": fixtureDate, "uptimeSeconds": hardware.uptime,
        "cpu": [
          "model": hardware.chip, "cores": hardware.cpuCores, "usedPercent": hardware.cpuLoad.last ?? 0,
          "history": loadSamples(hardware.cpuLoad),
        ] as [String: Any],
        "memory": capacity(hardware.memory), "disk": capacity(hardware.disk),
      ]
      if let gpuLoad = hardware.gpuLoad {
        stats["gpu"] = [
          "model": hardware.chip, "cores": hardware.gpuCores as Any, "usedPercent": gpuLoad.last ?? 0,
          "history": loadSamples(gpuLoad),
        ] as [String: Any]
      }
      return decode(stats)
    }

    static let usageLimits: ServerHarnessUsageLimits = decode([
      "state": "available", "harnessId": "claude-code", "plan": "max", "fetchedAt": fixtureDate,
      "accountEmail": DemoWorld.accounts.first { $0.isActive }?.email as Any,
      "windows": DemoWorld.usageWindows.map { window in
        [
          "id": window.id, "label": window.label, "usedPercent": window.usedPercent,
          "durationMinutes": window.durationMinutes,
          "resetsAt": ISO8601DateFormatter().string(from: DemoWorld.now.addingTimeInterval(window.resetsIn)),
        ] as [String: Any]
      },
    ])

    static let sessionContext: ServerSessionContext = {
      let used = DemoWorld.featuredContext.filter { !$0.isDeferred }.map(\.tokens).reduce(0, +)
      let free = DemoWorld.contextWindow - used - DemoWorld.autocompactBuffer
      let categories =
        DemoWorld.featuredContext.map { category in
          ["name": category.name, "tokens": category.tokens, "isDeferred": category.isDeferred] as [String: Any]
        } + [
          ["name": "Autocompact buffer", "tokens": DemoWorld.autocompactBuffer],
          ["name": "Free space", "tokens": free],
        ]
      return decode([
        "model": DemoWorld.featuredModel.id, "totalTokens": used, "maxTokens": DemoWorld.contextWindow,
        "categories": categories,
      ])
    }()

    static func navigationSnapshot(on machine: DemoWorld.Machine) -> ServerNavigationSnapshot {
      let projects = DemoWorld.projects.filter { $0.machine.deviceId == machine.deviceId }
      return decode([
        "eventCursor": 1,
        "projects": projects.map(navigationProject),
        "sessions": DemoModels.sessions.filter { $0.serverId == DemoModels.machineId(machine) }.map(navigationSession),
        "workspaces": projects.flatMap(navigationWorkspaces),
        "panes": projects.flatMap(navigationPanes),
      ])
    }

    private static func navigationProject(_ project: DemoWorld.Project) -> [String: Any] {
      let model = DemoModels.project(project)
      return [
        "id": model.id.uuidString, "name": project.name, "origin": "codevisor", "createdAt": fixtureDate,
        "locations": [
          [
            "id": project.name, "projectId": model.id.uuidString, "serverId": model.serverId,
            "folderPath": project.folderPath, "createdAt": fixtureDate, "isGitRepository": true,
          ] as [String: Any]
        ],
      ]
    }

    private static func navigationSession(_ session: ChatSession) -> [String: Any] {
      [
        "id": session.id.uuidString, "projectId": session.projectId.uuidString, "serverId": session.serverId,
        "harnessId": session.harnessId, "agentSessionId": session.agentSessionId as Any, "title": session.title,
        "origin": "codevisor", "createdAt": fixtureDate, "updatedAt": fixtureDate,
        "sidebarState": session.sidebarState.rawValue, "unreadCount": session.unreadCount,
      ]
    }

    private static func navigationWorkspaces(_ project: DemoWorld.Project) -> [[String: Any]] {
      project.chats.indices.map { chat in
        [
          "id": DemoModels.chatWorkspaceId(project, chat: chat).uuidString,
          "serverId": DemoModels.machineId(project.machine), "projectId": DemoModels.project(project).id.uuidString,
          "name": project.chats[chat].title, "hasCustomName": false, "rootDirectory": project.folderPath,
          "isArchived": false, "createdAt": fixtureDate,
          "sidebarPosition": String(format: "%04d", DemoModels.sidebarPosition(project, chat: chat)),
        ]
      }
    }

    private static func navigationPanes(_ project: DemoWorld.Project) -> [[String: Any]] {
      project.chats.indices.map { chat in
        let id = DemoModels.chatId(project, chat: chat).uuidString
        return [
          "id": id, "workspaceId": DemoModels.chatWorkspaceId(project, chat: chat).uuidString,
          "providerId": "codevisor", "createdAt": fixtureDate, "position": "0000", "paneType": "chat",
          "title": project.chats[chat].title, "resourceKind": "session", "resourceId": id,
        ]
      }
    }

    private static func loadSamples(_ load: [Double]) -> [[String: Any]] {
      load.enumerated().map { index, percent in
        let age = Double(load.count - 1 - index) * DemoWorld.loadSampleInterval
        return ["at": ISO8601DateFormatter().string(from: DemoWorld.now.addingTimeInterval(-age)), "usedPercent": percent]
      }
    }

    private static func capacity(_ capacity: DemoWorld.Capacity) -> [String: Any] {
      ["usedBytes": capacity.usedBytes, "totalBytes": capacity.totalBytes]
    }

    private static func decode<Value: Decodable>(_ object: Any) -> Value {
      try! JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }
#endif
