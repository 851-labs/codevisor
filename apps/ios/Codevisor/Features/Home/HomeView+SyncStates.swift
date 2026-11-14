import CodevisorCore
import SwiftUI

extension HomeView {
  var settingsButton: some View {
    Button {
      presentedSettingsDestination = .root
    } label: {
      Label("Settings", systemImage: "gearshape")
    }
  }

  private var presentation: HomeNavigationPresentation {
    navigationPresentation ?? .current(in: environment)
  }

  var launch: NavigationPresentation.Launch { presentation.launch }

  var syncIndicator: NavigationPresentation.SyncIndicator { presentation.syncIndicator }

  func refreshableState<Content: View>(
    allowsStateHitTesting: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    List {
      EmptyView()
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color(.systemBackground))
    .refreshable {
      await refreshNavigation()
    }
    .overlay {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(allowsStateHitTesting)
    }
  }

  func refreshNavigation() async {
    await machines.refreshNavigation()
  }
}
