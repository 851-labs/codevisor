import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorView: View {
  enum Destination: Equatable {
    case pullRequest(URL), link(URL), file(String)
  }

  let workspace: Workspace
  let project: Project
  let branch: String?
  let pullRequest: ServerGitPullRequest?
  let machineName: String?
  @Binding var tab: WorkspaceInspectorTab
  let media: WorkspaceInspectorMediaModel
  let fileTree: WorkspaceInspectorFileTreeModel
  let client: any CodevisorServerClienting
  let onReload: () -> Void
  let onOpen: (Destination) -> Void

  @Environment(\.theme) private var theme
  @State private var tabBarWidth: CGFloat = 0

  var body: some View {
    ZStack {
      switch tab {
      case .info: info
      case .photos: WorkspaceInspectorPhotosView(model: media, onRetry: onReload)
      case .links:
        WorkspaceInspectorLinksView(model: media, client: client, onOpen: onOpen, onRetry: onReload)
      case .sourceControl: WorkspaceInspectorSourceControlView(model: media, onOpen: onOpen, onRetry: onReload)
      case .files: WorkspaceInspectorFileTreeView(model: fileTree, onOpen: onOpen)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .top, spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          WorkspaceInspectorTabBar(selection: $tab)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: tabBarWidth)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: { width in
          tabBarWidth = width
          Task { proxy.scrollTo(tab, anchor: .center) }
        }
        .onChange(of: tab) { _, selected in
          withAnimation(.smooth(duration: 0.28)) { proxy.scrollTo(selected, anchor: .center) }
        }
      }
    }
  }

  private var info: some View {
    Form {
      if let pullRequest {
        Section("Pull Request") {
          row(.pullRequest(pullRequest.url)) {
            Label {
              Text("PR #\(pullRequest.number): \(pullRequest.title)")
                .lineLimit(1)
                .truncationMode(.tail)
            } icon: {
              pullRequest.statusImage
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(pullRequest.statusColor)
            }
          }
        }
      }

      Section("Details") {
        LabeledContent("Project", value: project.name)
        if let branch {
          LabeledContent("Branch", value: branch)
        }
        if let worktree = workspace.worktreeName {
          LabeledContent("Worktree", value: worktree)
        }
        if let machineName {
          LabeledContent("Machine", value: machineName)
        }
        LabeledContent("Created", value: workspace.createdAt, format: .relative(presentation: .named))
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
  }

  private func row(_ destination: Destination, @ViewBuilder label: () -> some View) -> some View {
    Button {
      onOpen(destination)
    } label: {
      label()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
