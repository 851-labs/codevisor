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
              SidebarWorkspaceRow(
                name: section.name, subtitle: section.machineName, icon: section.sidebarIcon, store: store,
                isSelected: section.rows.contains { $0.id == selectedRowID },
                isReordering: false, onActivate: {}, onNewTab: {}, onRename: {}, onArchive: {}
              )
            }
          }
        }
        .scrollContentBackground(.hidden)
      }
      .padding(.horizontal, 8)
      .themedSurface(.sidebar)
    }

    /// The tab the scene shows; its workspace's row is the selected one.
    private var selectedRowID: UUID? {
      switch scene {
      case "conversation": AppStoreScreenshotData.id(11)
      case "browser": AppStoreScreenshotData.id(13)
      default: nil
      }
    }
  }

  private extension ScreenshotSidebarSection {
    /// The chat carrying the section's status, as production picks a
    /// workspace's icon.
    var sidebarIcon: SidebarWorkspaceIcon {
      let chats = rows.filter { $0.session != nil }
      let chat = (chats.first { $0.status == status } ?? chats.first)?.session
      return chat.map(SidebarWorkspaceIcon.chat) ?? .workspace
    }
  }

  private extension ScreenshotSidebarTabRow {
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
