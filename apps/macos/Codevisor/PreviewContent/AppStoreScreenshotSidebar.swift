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
                name: section.name, machineName: section.machineName, status: section.sidebarStatus,
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
    var sidebarStatus: SidebarWorkspaceStatus {
      switch status {
      case .idle: .idle
      case .unread: .unread
      case .inProgress: .working
      }
    }
  }
#endif
