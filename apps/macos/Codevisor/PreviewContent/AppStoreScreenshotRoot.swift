#if DEBUG
  import AppKit
  import CodevisorCore
  import CodevisorUI
  import Combine
  import SwiftUI

  /// A separate entry point avoids live storage, account startup, and server launches.
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
    @State private var selection: SidebarSelection?

    var body: some View {
      NavigationSplitView {
        AppStoreScreenshotSidebar(scene: scene, store: fixture.store)
          .navigationSplitViewColumnWidth(270)
      } detail: {
        Group {
          if scene == "browser" {
            ChromiumBrowserPaneView(model: fixture.browser)
              .navigationTitle("Daylight")
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
      .modifier(ThemedRoot())
      .environment(fixture.environment)
      .preferredColorScheme(AppStoreScreenshotData.colorScheme)
      .background(MarketingWindowConfiguration())
    }
  }

  @MainActor
  private final class MacScreenshotFixture: ObservableObject {
    let environment = AppStoreScreenshotData.makeEnvironment()
    let controller = AppStoreScreenshotData.makeController()
    let focus = TerminalFocusController()
    lazy var store = SessionStore(environment: environment)
    lazy var transcript = TranscriptPresentationSurface(controller: controller)
    lazy var browser: ChromiumBrowserModel = {
      let data = AppStoreScreenshotData.self
      let model = ChromiumBrowserModel(
        paneId: data.id(7), machineId: "screenshot", machineName: "Studio Mac",
        initialURL: "http://localhost:3000", client: environment.machines.client(for: data.machineID),
        resolveBaseURL: { nil }
      )
      // A data URL keeps Chromium's real renderer offline. Its address bar retains
      // the example project's localhost URL, just as the iOS WKWebView does.
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

  /// Fix the outer window rectangle, including the native title bar.
  private struct MarketingWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObserver: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.setAccessibilityIdentifier("marketing-window")
        window.appearance = NSAppearance(named: AppStoreScreenshotData.colorScheme == .dark ? .darkAqua : .aqua)
        window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
        window.center()
      }
    }
  }
#endif
