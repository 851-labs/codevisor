#if DEBUG
  import CodevisorCore
  import CodevisorUI
  import Foundation
  import SwiftUI

  enum HomeSidebarSampleData {
    typealias Workspace = HomeSidebarWorkspace

    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["CODEVISOR_SIDEBAR_SAMPLE"] == "1"
    }

    @MainActor private static var didResetPreferences = false

    @MainActor static func resetPreferencesIfRequested() {
      guard !didResetPreferences, ProcessInfo.processInfo.environment["CODEVISOR_SIDEBAR_SAMPLE_RESET"] == "1"
      else { return }
      didResetPreferences = true
      for key in [
        SidebarGrouping.preferenceKey, SidebarGrouping.collapsedPreferenceKey, SidebarRowDetail.preferenceKey,
        SidebarPreferenceKey.pinnedWorkspaces, SidebarPreferenceKey.machineOrder, SidebarPreferenceKey.pinnedExpanded,
        SidebarPreferenceKey.listExpanded,
        SidebarPreferenceKey.archivedExpanded, HomeSidebarList.expandedWorkspacesKey,
      ] {
        ClientPreferences.shared.removeValue(forKey: key)
      }
    }

    struct Entry {
      var workspace: HomeSidebarWorkspace
      let projectId: UUID
      var branch: String? = nil
      var pullRequest: ServerGitPullRequest? = nil

      var item: WorkspaceSidebarItem {
        WorkspaceSidebarItem(id: workspace.id, serverId: workspace.serverId, projectId: projectId, routingChatIds: [])
      }
    }

    struct Sidebar: View {
      var isSelectable = false

      init(isSelectable: Bool = false) {
        self.isSelectable = isSelectable
        HomeSidebarSampleData.resetPreferencesIfRequested()
      }

      @State private var entries = AppStoreScreenshotData.isEnabled ? AppStoreScreenshotData.homeEntries : listed
      @State private var archivedEntries = AppStoreScreenshotData.isEnabled ? [] : archived
      @State private var selected: HomeSidebarSelection?
      @State private var handler = HomeSidebarActionHandler(HomeSidebarActions())
      @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedIDs: [String]

      var body: some View {
        handler.actions = actions
        return HomeSidebarList(
          makeContent: { HomeSidebarSampleData.content(entries, archived: archivedEntries, preferences: $0) },
          actions: handler,
          isSelectable: isSelectable,
          selected: selected
        )
      }

      private var actions: HomeSidebarActions {
        HomeSidebarActions(
          open: { row, ref in selected = HomeSidebarSelection(workspaceId: ref.id, paneId: row.id) },
          openWorkspace: { selected = HomeSidebarSelection(workspaceId: $0.id, paneId: $0.primaryRow?.id) },
          togglePin: { ref in
            let key = ref.id.uuidString
            if pinnedIDs.contains(key) { pinnedIDs.removeAll { $0 == key } } else { pinnedIDs.append(key) }
          },
          archiveWorkspace: { ref in
            guard let index = entries.firstIndex(where: { $0.workspace.id == ref.id }) else { return }
            pinnedIDs.removeAll { $0 == ref.id.uuidString }
            archivedEntries.insert(entries.remove(at: index), at: 0)
          },
          restoreWorkspace: { ref in
            guard let index = archivedEntries.firstIndex(where: { $0.workspace.id == ref.id }) else { return }
            entries.insert(archivedEntries.remove(at: index), at: 0)
          },
          reorder: { id, index, group in
            let order = ListReorder.moving(id, to: index, within: group, in: entries.map(\.workspace.id))
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.workspace.id, $0) })
            entries = order.compactMap { byID[$0] }
          }
        )
      }
    }

    static func content(
      _ entries: [Entry], archived: [Entry], preferences: HomeSidebarPreferences
    ) -> HomeSidebarContent {
      let byID = Dictionary(uniqueKeysWithValues: (entries + archived).map { ($0.workspace.id, $0) })
      return HomeSidebarContent.make(
        listed: entries.map(\.item),
        archived: archived.map(\.item),
        preferences: preferences,
        projects: projects,
        defaultServerId: studio,
        machineHeading: { serverId in
          let machine = machines[serverId]
          return SidebarWorkspaceGroup.Heading(
            title: machine?.name ?? "Unknown Machine",
            systemImage: machine?.systemImage ?? "questionmark.circle",
            newChatTarget: NewChatTarget(machine: serverId)
          )
        }
      ) { item, placement in
        guard let entry = byID[item.id] else { return nil }
        let details = preferences.rowDetails
        let underHeading = placement == .list
        var workspace = entry.workspace
        workspace.subtitle = SidebarRowSubtitle.make(
          details: details,
          projectName: projects.first { $0.id == entry.projectId }?.name,
          branch: entry.branch,
          groupNamesProject: preferences.grouping == .project && underHeading
        )
        workspace.machine =
          details.contains(.machine) && !(preferences.grouping == .machine && underHeading)
          ? machines[workspace.serverId] : nil
        workspace.pullRequest = details.contains(.pullRequest) ? entry.pullRequest : nil
        workspace.leadingRow =
          workspace.rows.filter { $0.status != .idle }.min { $0.status < $1.status }
          ?? workspace.rows.first { if case .chat = $0.icon { true } else { false } }
        workspace.isPinned = preferences.pinnedIDs.contains(workspace.id.uuidString)
        workspace.isArchived = placement == .archived
        return workspace
      }
    }

    static let studio = "sample-studio"
    static let linux = "sample-linux"

    static let machines: [String: HomeSidebarRowMachine] = [
      studio: HomeSidebarRowMachine(name: "Studio Mac", systemImage: "macstudio"),
      linux: HomeSidebarRowMachine(name: "Linux Box", systemImage: "server.rack"),
      "studio": HomeSidebarRowMachine(name: "Studio Mac", systemImage: "macstudio"),
      "linux": HomeSidebarRowMachine(name: "Linux Server", systemImage: "server.rack"),
    ]

    static let codevisorProject = Project(id: id(901), serverId: studio, name: "codevisor")
    static let landingProject = Project(id: id(902), serverId: studio, name: "landing")
    static let apiProject = Project(id: id(903), serverId: linux, name: "api")
    static let projects = [codevisorProject, landingProject, apiProject]

    static let listed: [Entry] = [
      Entry(
        workspace: workspace(
          1, "ios-sidebar", serverId: studio,
          rows: [
            row(
              11, "Port the sidebar to iPad", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"),
              status: .inProgress),
            row(
              12, "Add dark mode support",
              .chat(harnessId: "codex", fallbackSymbolName: "chevron.left.forwardslash.chevron.right"),
              status: .unread),
            row(13, "Terminal 1", .terminal),
            row(14, "Codevisor — localhost:3000", .browser(favicon: nil)),
          ]),
        projectId: codevisorProject.id, branch: "ios-sidebar",
        pullRequest: pullRequest(612, "Bring the refreshed sidebar to iOS", state: .open, checks: .pending)
      ),
      Entry(
        workspace: workspace(
          2, "landing-refresh", serverId: studio,
          rows: [
            row(
              21, "Refresh landing page copy", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"),
              status: .actionRequired),
            row(22, "Scratchpad", .plugin(pluginId: "851-labs.scratchpad", paneType: "scratchpad")),
            row(23, "README.md", .document),
          ]),
        projectId: landingProject.id, branch: "copy-refresh",
        pullRequest: pullRequest(88, "Refresh landing copy", state: .open, isDraft: true)
      ),
      Entry(
        workspace: workspace(
          3, "sessions-migration", serverId: linux,
          rows: [
            row(
              31, "Migrate sessions table", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"),
              status: .error),
            row(32, "Terminal 2", .terminal),
          ]),
        projectId: apiProject.id, branch: "sessions-migration",
        pullRequest: pullRequest(241, "Migrate sessions table", state: .open, checks: .failing)
      ),
      Entry(
        workspace: workspace(
          4, "onboarding-crash", serverId: studio,
          rows: [
            row(
              41, "Fix onboarding crash",
              .chat(harnessId: "codex", fallbackSymbolName: "chevron.left.forwardslash.chevron.right"))
          ]),
        projectId: codevisorProject.id, branch: "fix-onboarding-crash",
        pullRequest: pullRequest(605, "Fix onboarding crash", state: .open, checks: .passing)
      ),
      Entry(
        workspace: workspace(
          5, "docs-nav", serverId: studio,
          rows: [row(51, "Restructure docs navigation", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"))]
        ),
        projectId: landingProject.id, branch: "docs-nav",
        pullRequest: pullRequest(91, "Restructure docs navigation", state: .merged)
      ),
      Entry(
        workspace: workspace(6, "scratch", serverId: linux, rows: [row(61, "New Tab", .newTab)]),
        projectId: apiProject.id, branch: "main"
      ),
    ]

    static let archived: [Entry] = (0..<12).map { index in
      let names = [
        "rate-limits", "search-index", "flaky-tests", "theme-tokens", "auth-refresh", "pricing-page",
        "push-alerts", "metrics", "csv-export", "dark-icons", "sso-login", "cache-warmup",
      ]
      let project = projects[index % projects.count]
      return Entry(
        workspace: workspace(100 + index, names[index], serverId: project.serverId, rows: []),
        projectId: project.id, branch: names[index],
        pullRequest: index.isMultiple(of: 3)
          ? pullRequest(400 + index, names[index], state: index.isMultiple(of: 2) ? .merged : .closed) : nil
      )
    }

    static func id(_ value: Int) -> UUID {
      UUID(uuidString: String(format: "5A3D0000-0000-0000-0000-%012d", value))!
    }

    static func workspace(_ value: Int, _ name: String, serverId: String, rows: [HomeSidebarTabRow]) -> Workspace {
      HomeSidebarWorkspace(
        id: id(value), serverId: serverId, name: name, anchorSessionId: nil, primaryRowId: rows.first?.id,
        rows: rows)
    }

    static func row(
      _ value: Int,
      _ title: String,
      _ icon: HomeSidebarTabRow.Icon,
      status: HomeSessionStatus = .idle
    ) -> HomeSidebarTabRow {
      HomeSidebarTabRow(
        id: id(value),
        title: title,
        icon: icon,
        status: status,
        chatSessionId: nil,
        renamableTabId: id(value)
      )
    }

    private static func pullRequest(
      _ number: Int, _ title: String, state: ServerGitPullRequest.State, isDraft: Bool = false,
      checks: ServerGitPullRequest.Checks = .none
    ) -> ServerGitPullRequest {
      ServerGitPullRequest(
        number: number, title: title, state: state, isDraft: isDraft,
        url: URL(string: "https://github.com/851-labs/codevisor/pull/\(number)")!, checks: checks)
    }
  }
#endif
