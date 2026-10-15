import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorView: View {
  enum Destination {
    case changes, pullRequest(URL), desktop, browser, terminal, files
  }

  let workspace: Workspace
  let project: Project
  let branch: String?
  let pullRequest: ServerGitPullRequest?
  let machineName: String?
  let supportsDesktop: Bool
  let onOpen: (Destination) -> Void

  @Environment(\.theme) private var theme

  var body: some View {
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
              Image(pullRequest.statusIconName)
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
