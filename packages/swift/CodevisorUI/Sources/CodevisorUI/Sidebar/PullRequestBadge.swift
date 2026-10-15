import CodevisorCore
import SwiftUI

public struct PullRequestBadge: View {
  @Environment(\.openURL) private var openURL

  let pullRequest: ServerGitPullRequest
  let size: CGFloat
  let slot: CGFloat

  public init(pullRequest: ServerGitPullRequest, size: CGFloat, slot: CGFloat) {
    self.pullRequest = pullRequest
    self.size = size
    self.slot = slot
  }

  public var body: some View {
    Button {
      openURL(pullRequest.url)
    } label: {
      pullRequest.statusImage
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(pullRequest.statusColor)
        .frame(width: slot, height: slot)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("#\(pullRequest.number) · \(pullRequest.title) (\(summary))")
    .accessibilityLabel("Pull request \(pullRequest.number), \(summary)")
  }

  private var summary: String {
    guard let checksTitle else { return stateTitle }
    return "\(stateTitle), \(checksTitle)"
  }

  private var checksTitle: String? {
    switch pullRequest.checks {
    case .passing: "checks passing"
    case .failing: "checks failing"
    case .pending: "checks running"
    case .none: nil
    }
  }

  private var stateTitle: String {
    switch pullRequest.state {
    case .open: pullRequest.isDraft ? "Draft" : "Open"
    case .merged: "Merged"
    case .closed: "Closed"
    }
  }
}

extension ServerGitPullRequest {
  public var statusIconName: String {
    switch state {
    case .open: isDraft ? "octicon-git-pull-request-draft" : "octicon-git-pull-request"
    case .merged: "octicon-git-merge"
    case .closed: "octicon-git-pull-request-closed"
    }
  }

  public var statusImage: Image {
    Image(statusIconName, bundle: .module)
  }

  public var statusColor: Color {
    switch state {
    case .open where isDraft: .secondary
    case .open:
      switch checks {
      case .failing: .red
      case .pending: .orange
      case .passing, .none: .green
      }
    case .merged: .purple
    case .closed: .red
    }
  }
}
