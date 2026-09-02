import SwiftUI

/// Navigation and chrome mount without an indeterminate flash. If controller
/// or workspace preparation exceeds the grace period, the wait becomes
/// explicit while the async destination task continues.
struct DelayedWorkspaceLoadingView: View {
  @State private var showsSpinner = false

  var body: some View {
    ZStack {
      Color.clear
      if showsSpinner {
        ProgressView()
          .accessibilityLabel("Loading conversation")
      }
    }
    .task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      showsSpinner = true
    }
  }
}
