import CodevisorUI

#if DEBUG
  import AppKit
  import CodevisorCore
  import CodevisorUI
  import Combine
  import SwiftUI

  struct AppStoreScreenshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
      WindowGroup("Codevisor") {
        AppStoreScreenshotRoot()
      }
      .defaultSize(width: 1280, height: 820)
      .windowResizability(.contentMinSize)
    }
  }

  private struct AppStoreScreenshotRoot: View {
    private let scene = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"] ?? "projects"
    @StateObject private var fixture = MacScreenshotFixture()
    @State private var selection = Self.initialSelection
    @State private var panelLayout = AdaptivePanelLayout()

    var body: some View {
      Group {
        if fixture.isReady { content } else { Color.clear }
      }
      .modifier(ThemedRoot())
      .environment(fixture.environment)
      .environment(panelLayout)
      .environment(\.inspectorNow, DemoWorld.now)
      .preferredColorScheme(AppStoreScreenshotData.colorScheme)
      .background(MarketingWindowConfiguration())
      .task {
        await fixture.prepare()
        await MarketingWindowAnnouncement.announce()
      }
    }

    private static var initialSelection: SidebarSelection? {
      switch ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"] {
      case "conversation", "browser":
        .session(serverId: AppStoreScreenshotData.machineID, id: AppStoreScreenshotData.sessionID)
      default: nil
      }
    }

    @ViewBuilder private var content: some View {
      if AppStoreScreenshotData.showsInspector {
        splitView.modifier(WorkspaceInspectorPresentation(store: fixture.store, selection: inspectedSelection))
      } else {
        splitView
      }
    }

    private var inspectedSelection: SidebarSelection {
      .session(serverId: AppStoreScreenshotData.machineID, id: AppStoreScreenshotData.sessionID)
    }

    private var splitView: some View {
      NavigationSplitView {
        SidebarView(selection: $selection, store: fixture.store, publishesSceneActions: false)
          .navigationSplitViewColumnWidth(270)
      } detail: {
        Group {
          if scene == "browser" {
            ChromiumBrowserPaneView(model: fixture.browser)
              .navigationTitle(DemoWorld.featuredProject.name)
              .toolbar {
                ChromiumBrowserNavigationControls(model: fixture.browser)
                ChromiumBrowserAddressToolbarItem(model: fixture.browser, width: 560)
              }
          } else if scene == "conversation" {
            ChatScreen(
              controller: fixture.controller, focus: fixture.focus,
              presentationSurface: fixture.transcript
            )
            .navigationTitle(AppStoreScreenshotData.title)
          } else {
            NewChatView(
              store: fixture.store, selection: $selection,
              initialProjectTarget: scene == "new-chat" ? NewChatTarget(AppStoreScreenshotData.project) : nil
            )
          }
        }
        .background(Color(nsColor: .windowBackgroundColor))
      }
    }
  }

  @MainActor
  private final class MacScreenshotFixture: ObservableObject {
    let environment = AppStoreScreenshotData.makeEnvironment()
    @Published private(set) var isReady = false
    let controller = AppStoreScreenshotData.makeController()
    let focus = TerminalFocusController()
    lazy var store = SessionStore(environment: environment)
    lazy var transcript = TranscriptPresentationSurface(controller: controller)

    func prepare() async {
      ClientPreferences.shared.set(SidebarGrouping.machine, forKey: SidebarGrouping.preferenceKey)
      if AppStoreScreenshotData.showsInspector {
        ClientPreferences.shared.set(true, forKey: WorkspaceInspectorPresentation.presentedKey)
      }
      await DemoEnvironment.connect(environment)
      isReady = true
    }

    lazy var browser: ChromiumBrowserModel = {
      let data = AppStoreScreenshotData.self
      let model = ChromiumBrowserModel(
        paneId: data.browserPaneID, machineId: data.machineID, machineName: data.machineName,
        initialURL: DemoWorld.previewURL, client: environment.machines.client(for: data.machineID),
        resolveBaseURL: { nil }
      )
      let html = Data(AppStoreScreenshotPage.html.utf8).base64EncodedString()
      let view = CVChromiumView(
        profile: "marketing-\(ProcessInfo.processInfo.processIdentifier)",
        proxyHost: "screenshots.invalid", proxyPort: 443, proxyTLS: true, username: "", password: "",
        address: "data:text/html;charset=utf-8;base64,\(html)"
      )
      model.adoptPopup(view)
      return model
    }()
  }

  private enum MarketingWindowAnnouncement {
    static func announce() async {
      guard let path = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_WINDOW_FILE"],
        let window = NSApp.windows.first(where: { $0.accessibilityIdentifier() == "marketing-window" })
      else { return }
      if MarketingDesktop.isEnabled {
        MarketingDesktop.hideOtherApps()
      } else {
        MarketingBackdrop.show(behind: window)
      }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      for _ in 0..<20 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
      MarketingWindowSize.apply(to: window)
      try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
    }
  }

  private enum MarketingBackdrop {
    private static var window: NSWindow?

    static func show(behind appWindow: NSWindow) {
      guard let screen = appWindow.screen ?? NSScreen.main else { return }
      let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      backdrop.isReleasedWhenClosed = false
      backdrop.appearance = appWindow.appearance
      backdrop.backgroundColor = .windowBackgroundColor
      backdrop.isOpaque = true
      backdrop.ignoresMouseEvents = true
      backdrop.setFrame(screen.frame, display: true)
      backdrop.order(.below, relativeTo: appWindow.windowNumber)
      window = backdrop
    }
  }

  private enum MarketingWindowSize {
    static var requested: NSSize? {
      let parts = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_WINDOW_SIZE"]?
        .split(separator: "x").compactMap { Double($0) }
      guard let parts, parts.count == 2 else { return nil }
      return NSSize(width: parts[0], height: parts[1])
    }

    static var isRequested: Bool { requested != nil || MarketingDesktop.isEnabled }

    static func apply(to window: NSWindow) {
      guard isRequested, let screen = window.screen ?? NSScreen.main else { return }
      if NSApp.isActive { NSApp.presentationOptions = [.autoHideDock] }
      let frame = requested.map { NSRect(origin: screen.frame.origin, size: $0) } ?? MarketingDesktop.frame(on: screen)
      window.setFrame(frame, display: true)
    }
  }

  @MainActor
  private enum MarketingDesktop {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_DESKTOP"] == "1"
    }

    private static let inset: CGFloat = 40
    private static var hidden: [NSRunningApplication] = []
    private static var termination: DispatchSourceSignal?

    static func frame(on screen: NSScreen) -> NSRect {
      let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
      var desktop = screen.frame
      desktop.size.height -= menuBarHeight
      return desktop.insetBy(dx: inset, dy: inset)
    }

    static func hideOtherApps() {
      hidden = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current
      }
      hidden.forEach { $0.hide() }
      signal(SIGTERM, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      source.setEventHandler {
        hidden.forEach { $0.unhide() }
        exit(0)
      }
      source.resume()
      termination = source
    }
  }

  private struct MarketingWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObserver: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.setAccessibilityIdentifier("marketing-window")
        window.appearance = NSAppearance(named: AppStoreScreenshotData.colorScheme == .dark ? .darkAqua : .aqua)
        if MarketingWindowSize.isRequested {
          MarketingWindowSize.apply(to: window)
        } else {
          window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
          window.center()
        }
      }

    }
  }
#endif
