#if DEBUG
  import CodevisorCore

  extension AppStoreScreenshotData {
    static var homeSections: [HomeSidebarSection] {
      sections.map { section in
        HomeSidebarSection(
          id: section.id, serverId: section.serverId, name: section.name,
          machineName: section.machineName, anchorSessionId: section.anchorSessionId,
          status: section.status.homeStatus,
          rows: section.rows.map { row in
            HomeSidebarTabRow(
              id: row.id, title: row.title, icon: row.icon.homeIcon, status: row.status.homeStatus,
              chatSessionId: row.chatSessionId, renamableTabId: row.renamableTabId
            )
          }
        )
      }
    }
  }

  private extension ScreenshotSessionStatus {
    var homeStatus: HomeSessionStatus {
      switch self {
      case .idle: .idle
      case .unread: .unread
      case .inProgress: .inProgress
      }
    }
  }

  private extension ScreenshotSidebarTabRow.Icon {
    var homeIcon: HomeSidebarTabRow.Icon {
      switch self {
      case let .chat(harnessId, fallbackSymbolName): .chat(harnessId: harnessId, fallbackSymbolName: fallbackSymbolName)
      case .browser: .browser(favicon: nil)
      case let .terminal(isAgentOwned): .terminal(isAgentOwned: isAgentOwned)
      case .document: .document
      }
    }
  }
#endif
