import SwiftUI

struct ActiveWorkspaceDropDestination<Destination: View>: ViewModifier {
  @ViewBuilder let destination: () -> Destination

  func body(content: Content) -> some View {
    content.background {
      ActiveWorkspaceOnly(content: destination)
    }
  }
}

extension View {
  func activeWorkspaceDropDestination<Destination: View>(
    @ViewBuilder _ destination: @escaping () -> Destination
  ) -> some View {
    modifier(ActiveWorkspaceDropDestination(destination: destination))
  }
}
