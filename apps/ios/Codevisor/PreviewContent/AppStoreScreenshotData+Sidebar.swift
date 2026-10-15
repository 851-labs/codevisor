#if DEBUG
  import CodevisorCore

  extension AppStoreScreenshotData {
    static var homeEntries: [HomeSidebarSampleData.Entry] {
      sections.map { section in
        HomeSidebarSampleData.Entry(
          workspace: HomeSidebarWorkspace(
            id: section.id, serverId: section.serverId, name: section.name,
            anchorSessionId: section.anchorSessionId, primaryRowId: section.rows.first?.id,
            rows: section.rows.map { row in
              HomeSidebarTabRow(
                id: row.id, title: row.title, icon: row.icon.homeIcon, status: row.status.homeStatus,
                chatSessionId: row.chatSessionId, renamableTabId: row.renamableTabId
              )
            }
          ),
          projectId: section.id
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
      case .terminal: .terminal
      case .document: .document
      }
    }
  }
#endif
