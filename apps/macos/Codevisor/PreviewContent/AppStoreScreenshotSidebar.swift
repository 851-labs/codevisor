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
              AgentRowView(
                row: AgentSidebarRow(
                  id: section.id, title: section.name, serverId: AppStoreScreenshotData.machineID,
                  projectId: AppStoreScreenshotData.projectID, branch: nil,
                  status: section.status == .inProgress ? .working : .idle,
                  subagents: [], position: ""),
                detail: section.machineName,
                isSelected: scene == "conversation" && section.id == AppStoreScreenshotData.sections.first?.id,
                isExpanded: false, showsSubagents: false, onActivate: {}, onToggle: {}
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
