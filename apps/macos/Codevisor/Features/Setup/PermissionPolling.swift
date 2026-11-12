import SwiftUI

struct PermissionPolling: ViewModifier {
  let refresh: () async -> Void
  @Environment(\.controlActiveState) private var controlActiveState

  func body(content: Content) -> some View {
    content
      .task { await poll() }
      .onChange(of: controlActiveState) { _, _ in
        Task { await refresh() }
      }
  }

  private func poll() async {
    while !Task.isCancelled {
      await refresh()
      try? await Task.sleep(for: .seconds(1))
    }
  }
}
