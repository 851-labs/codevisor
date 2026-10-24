#if DEBUG
  import CodevisorCore
  import Foundation

  nonisolated enum DemoModels {
    static let date = DemoWorld.now.addingTimeInterval(-chatAge)
    private static let chatAge: TimeInterval = 20 * 60

    private static let workspaceIdBase = 100
    private static let projectIdBase = 200
    private static let chatsPerProject = 10
    private static let chatWorkspaceIdBase = 600

    static func id(_ value: Int) -> UUID {
      UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func machineId(_ machine: DemoWorld.Machine) -> String {
      machine.deviceId == DemoWorld.thisMac.deviceId
        ? CodevisorMachine.local.id : CodevisorMachine.cloudIdPrefix + machine.deviceId
    }

    static func machine(forMachineId machineId: String) -> DemoWorld.Machine {
      DemoWorld.machines.first { self.machineId($0) == machineId } ?? DemoWorld.thisMac
    }

    static let projects = DemoWorld.projects.map(project)
    static let sessions = DemoWorld.projects.flatMap(sessions)

    static func project(_ project: DemoWorld.Project) -> Project {
      let id = id(projectIdBase + index(of: project))
      let serverId = machineId(project.machine)
      return Project(
        id: id, serverId: serverId, name: project.name, createdAt: date,
        locations: [
          ProjectLocation(
            id: project.name, projectId: id, serverId: serverId, folderPath: project.folderPath, isGitRepository: true)
        ])
    }

    static func chatId(_ project: DemoWorld.Project, chat: Int) -> UUID {
      id(workspaceIdBase + index(of: project) * chatsPerProject + chat + 1)
    }

    static func chatWorkspaceId(_ project: DemoWorld.Project, chat: Int) -> UUID {
      id(chatWorkspaceIdBase + index(of: project) * chatsPerProject + chat)
    }

    static func sidebarPosition(_ project: DemoWorld.Project, chat: Int) -> Int {
      index(of: project) * chatsPerProject + chat
    }

    static var featuredWorkspaceId: UUID {
      let project = DemoWorld.featuredProject
      let chat = project.chats.firstIndex { $0.title == DemoWorld.featuredChat.title }!
      return chatWorkspaceId(project, chat: chat)
    }

    static var featuredSession: ChatSession {
      sessions.first { $0.title == DemoWorld.featuredChat.title }!
    }

    private static func sessions(_ project: DemoWorld.Project) -> [ChatSession] {
      project.chats.enumerated().map { offset, chat in
        session(chat, id: chatId(project, chat: offset), in: project)
      }
    }

    private static func session(_ chat: DemoWorld.Chat, id: UUID, in project: DemoWorld.Project) -> ChatSession {
      ChatSession(
        id: id, projectId: self.project(project).id, serverId: machineId(project.machine), harnessId: chat.harnessId,
        agentSessionId: "demo-\(id.uuidString)", title: chat.title, createdAt: date, updatedAt: date,
        sidebarState: sidebarState(chat.status), unreadCount: chat.status == .unread ? 1 : 0)
    }

    static func sidebarState(_ status: DemoWorld.ChatStatus) -> SessionSidebarState {
      switch status {
      case .idle: .idle
      case .unread: .unread
      case .inProgress: .inProgress
      }
    }

    private static func index(of project: DemoWorld.Project) -> Int {
      DemoWorld.projects.firstIndex { $0.name == project.name }!
    }
  }
#endif
