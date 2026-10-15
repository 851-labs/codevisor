import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorView: View {
  enum Destination: Equatable {
    case changes, pullRequest(URL), desktop, browser, terminal, files
    case link(URL), browserPane(UUID)
  }

  let workspace: Workspace
  let project: Project
  let branch: String?
  let pullRequest: ServerGitPullRequest?
  let machineName: String?
  let supportsDesktop: Bool
  @Binding var tab: WorkspaceInspectorTab
  let media: WorkspaceInspectorMediaModel
  let openTabs: [WorkspaceInspectorOpenTab]
  let client: any CodevisorServerClienting
  let onReload: () -> Void
  let onOpen: (Destination) -> Void

  @Environment(\.theme) private var theme

  var body: some View {
    Group {
      switch tab {
      case .info: info
      case .photos: WorkspaceInspectorPhotosView(model: media, onRetry: onReload)
      case .links:
        WorkspaceInspectorLinksView(
          openTabs: openTabs, model: media, client: client, onOpen: onOpen, onRetry: onReload)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .top, spacing: 0) {
      Picker("Inspector Section", selection: $tab) {
        ForEach(WorkspaceInspectorTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }

  private var info: some View {
    Form {
      Section {
        row(.changes) { Label("Changes", systemImage: "plus.forwardslash.minus") }
        if let pullRequest {
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
        row(.desktop) { Label("Desktop", systemImage: "desktopcomputer") }
          .disabled(!supportsDesktop)
        row(.browser) { Label("Browser", systemImage: "globe") }
        row(.terminal) { Label("Terminal", systemImage: "apple.terminal") }
        row(.files) { Label("Files", systemImage: "doc") }
      } header: {
        Text("On \(project.name)/\(branch ?? workspace.worktreeName ?? workspace.name)")
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

      if let directory = workspace.rootDirectory {
        Section("Location") {
          Text(directory)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
        }
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
