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
      pullRequest.statusSymbol.image
        .font(.system(size: size))
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
  public var statusSymbol: CodevisorSymbol {
    switch state {
    case .open where isDraft: .gitPullRequestDraft
    case .open: checksSymbol
    case .merged: .gitMerge
    case .closed: .gitPullRequestClosed
    }
  }

  private var checksSymbol: CodevisorSymbol {
    switch checks {
    case .passing: .gitBranchCheck
    case .failing: .gitBranchX
    case .pending: .gitBranchDot
    case .none: .gitPullRequest
    }
  }

  public var statusColor: Color {
    switch state {
    case .open where isDraft: PullRequestPalette.draft
    case .open: checksColor
    case .merged: PullRequestPalette.merged
    case .closed: PullRequestPalette.closed
    }
  }

  private var checksColor: Color {
    switch checks {
    case .failing: PullRequestPalette.failing
    case .pending: PullRequestPalette.pending
    case .passing, .none: PullRequestPalette.open
    }
  }
}
