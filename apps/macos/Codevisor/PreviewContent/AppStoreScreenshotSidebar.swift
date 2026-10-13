#if DEBUG
  import CodevisorCore
  import CodevisorUI
  import SwiftUI

  /// The production sidebar rows, populated from the same records as iOS.
  struct AppStoreScreenshotSidebar: View {
    let scene: String
    let store: SessionStore

    var body: some View {
      VStack(spacing: 0) {
        SidebarActionRow(
          title: "New chat", systemImage: "square.and.pencil", isSelected: scene == "new-chat", isHoverEnabled: false
        ) {}
        .padding(.top, 8)
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(AppStoreScreenshotData.sections) { section in
              SidebarWorkspaceHeader(
                name: section.name, machineName: section.machineName, isReordering: false,
                onArchive: {}, onRename: {}, onNewTab: {}
              )
              ForEach(section.rows) { row in
                SidebarWorkspaceTabRow(
                  title: row.title, kind: row.kind, isAgentOwned: false,
                  chatSession: row.session, store: store,
                  isSelected: (scene == "conversation" && row.id == AppStoreScreenshotData.id(11))
                    || (scene == "browser" && row.id == AppStoreScreenshotData.id(13)),
                  isReordering: false, titleFont: .body, onActivate: {}, onClose: {}
                )
              }
            }
          }
        }
        .scrollContentBackground(.hidden)
      }
      .padding(.horizontal, 8)
      .themedSurface(.sidebar)
    }
  }

  private extension ScreenshotSidebarTabRow {
    var kind: PaneKind {
      switch icon {
      case .chat: .chat
      case .browser: .browser
      case .terminal: .terminal
      case .document: .document
      }
    }

    var session: ChatSession? {
      guard case let .chat(harnessId, _) = icon else { return nil }
      return ChatSession(
        id: id, projectId: AppStoreScreenshotData.projectID,
        serverId: AppStoreScreenshotData.machineID, harnessId: harnessId,
        title: title, createdAt: AppStoreScreenshotData.date, updatedAt: AppStoreScreenshotData.date,
        sidebarState: status == .inProgress ? .inProgress : (status == .unread ? .unread : .idle),
        unreadCount: status == .unread ? 1 : 0
      )
    }
  }
#endif
