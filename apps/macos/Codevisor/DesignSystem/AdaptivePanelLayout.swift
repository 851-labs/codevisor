import SwiftUI
import CodevisorUI

enum AdaptiveDrawer: Equatable {
  case leading
}

@MainActor
@Observable
final class AdaptivePanelLayout {
  private static let sidebarCollapseWidth: CGFloat = 720
  private static let sidebarRestoreWidth: CGFloat = 760

  private(set) var windowWidth: CGFloat = 1_280
  private(set) var docksSidebar = true
  private(set) var activeDrawer: AdaptiveDrawer?

  func updateWindowWidth(_ width: CGFloat) {
    guard width.isFinite, width > 0, abs(width - windowWidth) > 0.5 else { return }
    windowWidth = width

    if docksSidebar, width < Self.sidebarCollapseWidth {
      docksSidebar = false
    } else if !docksSidebar, width > Self.sidebarRestoreWidth {
      docksSidebar = true
      if activeDrawer == .leading { activeDrawer = nil }
    }
  }

  func toggleDrawer(_ drawer: AdaptiveDrawer) {
    activeDrawer = activeDrawer == drawer ? nil : drawer
  }

  func dismissDrawer(_ drawer: AdaptiveDrawer? = nil) {
    guard drawer == nil || activeDrawer == drawer else { return }
    activeDrawer = nil
  }
}

struct AdaptiveDrawerLayer<DrawerContent: View>: View {
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isPresented: Bool
  let edge: Edge
  let width: CGFloat
  @ViewBuilder var drawerContent: () -> DrawerContent

  var body: some View {
    ZStack(alignment: edge == .leading ? .leading : .trailing) {
      if isPresented {
        Color.black.opacity(0.12)
          .contentShape(Rectangle())
          .onTapGesture { panelLayout.dismissDrawer() }
          .transition(.opacity)

        drawerContent()
          .frame(width: width)
          .padding(8)
          .transition(.move(edge: edge).combined(with: .opacity))
      }
    }
    .allowsHitTesting(isPresented)
    .onExitCommand { panelLayout.dismissDrawer() }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isPresented)
  }
}
