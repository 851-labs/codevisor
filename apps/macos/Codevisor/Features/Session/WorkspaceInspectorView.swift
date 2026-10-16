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
  let activeFilePath: String?
  let client: any CodevisorServerClienting
  let onReload: () -> Void
  let onOpen: (Destination) -> Void

  @State private var tabBarWidth: CGFloat = 0
  @State private var visited: Set<WorkspaceInspectorTab> = []

  var body: some View {
    ZStack {
      ForEach(WorkspaceInspectorTab.allCases.filter { $0 == tab || visited.contains($0) }) { candidate in
        content(for: candidate)
          .opacity(candidate == tab ? 1 : 0)
          .allowsHitTesting(candidate == tab)
          .disabled(candidate != tab)
          .accessibilityHidden(candidate != tab)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: tab, initial: true) { _, selected in visited.insert(selected) }
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
          Task { proxy.scrollTo(tab) }
        }
        .onChange(of: tab) { _, selected in
          withAnimation(.smooth(duration: 0.28)) { proxy.scrollTo(selected) }
        }
      }
    }
  }

  @ViewBuilder
  private func content(for tab: WorkspaceInspectorTab) -> some View {
    switch tab {
    case .info: info
    case .photos: WorkspaceInspectorPhotosView(model: media, onRetry: onReload)
    case .links:
      WorkspaceInspectorLinksView(model: media, client: client, onOpen: onOpen, onRetry: onReload)
    case .sourceControl: WorkspaceInspectorSourceControlView(model: media, onOpen: onOpen, onRetry: onReload)
    case .files: WorkspaceInspectorFileTreeView(model: fileTree, activeFilePath: activeFilePath, onOpen: onOpen)
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
