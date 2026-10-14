import ComposableArchitecture
import ScreenSharing
import SwiftUI

public struct ScreenSharingSystemKeyButton: View {
  let store: StoreOf<ScreenSharingViewer>
  let key: ScreenSharingSystemKey

  public init(store: StoreOf<ScreenSharingViewer>, key: ScreenSharingSystemKey) {
    self.store = store
    self.key = key
  }

  public var body: some View {
    Button(key.title, systemImage: key.systemImage) { store.send(.systemKeyTapped(key)) }
      .labelStyle(.iconOnly)
      .help(key.title)
  }
}

extension ScreenSharingSystemKey {
  public var title: String {
    switch self {
    case .apps: "Apps"
    case .missionControl: "Mission Control"
    case .desktop: "Desktop"
    }
  }

  public var systemImage: String {
    switch self {
    case .apps: "square.grid.3x3"
    case .missionControl: "rectangle.3.group"
    case .desktop: "menubar.dock.rectangle"
    }
  }
}
