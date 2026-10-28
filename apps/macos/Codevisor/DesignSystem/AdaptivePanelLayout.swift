import AppKit
import SwiftUI
import CodevisorUI

enum AdaptiveDrawer: Equatable {
  case leading
  case trailing
}

@MainActor
@Observable
final class AdaptivePanelLayout {
  private static let inspectorCollapseWidth: CGFloat = 960
  private static let inspectorRestoreWidth: CGFloat = 1_000
  private static let sidebarCollapseWidth: CGFloat = 720
  private static let sidebarRestoreWidth: CGFloat = 760

  private(set) var windowWidth: CGFloat = 1_280
  private(set) var isFullScreen = false
  private(set) var docksSidebar = true
  private(set) var docksInspector = true
  private(set) var activeDrawer: AdaptiveDrawer?

  func updateWindow(width: CGFloat, isFullScreen: Bool) {
    if self.isFullScreen != isFullScreen { self.isFullScreen = isFullScreen }
    updateWindowWidth(width)
  }

  private func updateWindowWidth(_ width: CGFloat) {
    guard width.isFinite, width > 0, abs(width - windowWidth) > 0.5 else { return }
    windowWidth = width

    if docksInspector, width < Self.inspectorCollapseWidth {
      docksInspector = false
    } else if !docksInspector, width > Self.inspectorRestoreWidth {
      docksInspector = true
      if activeDrawer == .trailing { activeDrawer = nil }
    }

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

struct WindowLayoutReader: NSViewRepresentable {
  let onChange: @MainActor (_ width: CGFloat, _ isFullScreen: Bool) -> Void

  func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
  func updateNSView(_ nsView: Probe, context: Context) { nsView.onChange = onChange }

  final class Probe: NSView {
    var onChange: @MainActor (_ width: CGFloat, _ isFullScreen: Bool) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor (_ width: CGFloat, _ isFullScreen: Bool) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      let notifications = [
        NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
      ]
      observers = notifications.map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.report() }
        }
      }
      report()
    }

    private func report() {
      guard let window else { return }
      onChange(window.contentLayoutRect.width, window.styleMask.contains(.fullScreen))
    }
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
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    ZStack(alignment: edge == .leading ? .leading : .trailing) {
      if isPresented {
        Color.black.opacity(0.12)
          .contentShape(Rectangle())
          .onTapGesture { panelLayout.dismissDrawer() }
          .transition(.opacity)

        drawerContent()
          .frame(width: width)
          .scrollContentBackground(.hidden)
          .glassEffect(.regular, in: shape)
          .clipShape(shape)
          .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
          .padding(8)
          .transition(.move(edge: edge).combined(with: .opacity))
      }
    }
    .allowsHitTesting(isPresented)
    .onExitCommand { panelLayout.dismissDrawer() }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isPresented)
  }
}
