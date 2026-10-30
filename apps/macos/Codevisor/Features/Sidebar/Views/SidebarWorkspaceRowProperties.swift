import CodevisorClient
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceRowProperties: View {
  let pullRequest: ServerGitPullRequest?
  let machine: SidebarRowMachine?

  var body: some View {
    HStack(spacing: SidebarWorkspaceRow.trailingSpacing) {
      if let pullRequest {
        PullRequestBadge(
          pullRequest: pullRequest, size: SidebarRowIcon.trailingSize, slot: SidebarRowIcon.trailingSlot)
      }
      if let machine {
        Image(systemName: machine.systemImage)
          .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
          .help(machine.name)
          .accessibilityLabel("On \(machine.name)")
      }
    }
  }
}
