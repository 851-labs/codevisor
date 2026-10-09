#if DEBUG
  import CodevisorCore
  import CodevisorUI
  import SwiftUI

  /// The production sidebar rows: one per agent, drawn from its own chat.
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
              SidebarWorkspaceTabRow(
                title: section.rows.first?.title ?? section.name, kind: .chat, isAgentOwned: false,
                chatSession: store.environment.projectList.session(
                  section.anchorSessionId, serverId: section.serverId),
                store: store,
                isSelected: scene == "conversation" && section.id == AppStoreScreenshotData.sections.first?.id,
                isReordering: false, titleFont: .body, onActivate: {}, onClose: {}
              )
            }
          }
        }
        .scrollContentBackground(.hidden)
      }
      .padding(.horizontal, 8)
      .themedSurface(.sidebar)
    }
  }

#endif
