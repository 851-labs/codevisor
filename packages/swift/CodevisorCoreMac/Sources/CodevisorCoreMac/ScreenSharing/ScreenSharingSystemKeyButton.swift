import ComposableArchitecture
import ScreenSharing
import SwiftUI

/// Apps, Mission Control or Desktop on the host, like Apple Screen Sharing's toolbar (851-2469).
/// They press the host's own keys, so they work only while controlling.
///
/// One toolbar item per key: three buttons inside one item reached Accessibility all named after
/// the first ("Apps"), and inside a ControlGroup as bare groups with no name or press action, so
/// VoiceOver couldn't use them.
public struct ScreenSharingSystemKeyButton: View {
  let store: StoreOf<ScreenSharingViewer>
  let key: ScreenSharingSystemKey

  public init(store: StoreOf<ScreenSharingViewer>, key: ScreenSharingSystemKey) {
    self.store = store
    self.key = key
  }

  public var body: some View {
    Button(key.title, systemImage: key.systemImage) { store.endpoint?.tap(key) }
      .labelStyle(.iconOnly)
      .help(key.title)
      .disabled(store.lease?.phase != .controlling)
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
