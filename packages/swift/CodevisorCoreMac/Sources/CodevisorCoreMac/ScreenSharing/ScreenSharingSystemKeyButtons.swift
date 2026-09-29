import ComposableArchitecture
import ScreenSharing
import SwiftUI

/// Apps, Mission Control and Desktop on the host, like Apple Screen Sharing's toolbar (851-2469).
/// They press the host's own keys, so they work only while controlling.
public struct ScreenSharingSystemKeyButtons: View {
  let store: StoreOf<ScreenSharingViewer>

  public init(store: StoreOf<ScreenSharingViewer>) { self.store = store }

  public var body: some View {
    ControlGroup {
      ForEach(ScreenSharingSystemKey.allCases, id: \.self) { key in
        Button {
          store.endpoint?.tap(key)
        } label: {
          Label(key.title, systemImage: key.systemImage).labelStyle(.iconOnly)
        }
        .help(key.title)
      }
    }
    .disabled(store.lease?.phase != .controlling)
    .fixedSize()
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
