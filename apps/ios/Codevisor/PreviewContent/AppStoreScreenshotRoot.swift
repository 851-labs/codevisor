#if DEBUG
  import CodevisorCore
  import CodevisorUI
  import Combine
  import SwiftUI
  import WebKit

  /// Mounts the shipping SwiftUI surfaces with offline preview models. This
  /// branch runs before normal startup, so it never opens account storage.
  struct AppStoreScreenshotRoot: View {
    private let scene = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"] ?? "projects"
    @StateObject private var fixture = AppStoreScreenshotFixture()
    @State private var path = ["detail"]

    var body: some View {
      Group {
        if scene == "projects" || scene == "new-chat" {
          HomeView()
        } else {
          NavigationStack(path: $path) {
            Color.clear
              .navigationDestination(for: String.self) { _ in
                if scene == "browser" {
                  BrowserPaneView(model: fixture.browser)
                    .navigationTitle("Daylight")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                      WorkspaceScreenToolbar(
                        isNewChatPresentation: false, isPromotingNewChat: false, blocksServerContent: false,
                        isDraft: false, onDismissNewChat: {}, onAddTab: {}
                      )
                    }
                } else {
                  WorkspaceScreen(
                    sessionId: AppStoreScreenshotData.sessionID, serverId: AppStoreScreenshotData.machineID,
                    initialController: fixture.controller
                  )
                }
              }
          }
        }
      }
      .modifier(ThemedRoot())
      .environment(fixture.environment)
      .preferredColorScheme(AppStoreScreenshotData.colorScheme)
    }
  }

  /// StateObject's deferred initializer keeps fixture registration out of body
  /// evaluation and guarantees one environment/controller set per launch.
  @MainActor
  private final class AppStoreScreenshotFixture: ObservableObject {
    let environment: AppEnvironment
    let controller: SessionController
    let browser: BrowserPaneModel

    init() {
      let data = AppStoreScreenshotData.self
      let environment = data.makeEnvironment()
      let controller = data.makeController()
      let panes = PaneGroupState(
        panes: [
          PaneDescriptorState(
            id: data.paneID, kind: .chat, name: data.title, terminalKey: "screenshot", chatSessionId: data.sessionID)
        ], selectedPaneId: data.paneID)
      environment.paneGroups.save(panes, sessionId: data.sessionID)
      _ = environment.workspaces.ensureWorkspace(
        for: WorkspaceSessionSeed(
          sessionId: data.sessionID, initialName: "daylight", serverId: data.machineID, projectId: data.projectID,
          rootDirectory: "/projects/daylight", assignedWorkspaceId: data.id(6)
        ), legacyGroups: environment.paneGroups)
      ChatControllerCache.shared.register(controller, for: data.session, environment: environment)
      let browser = BrowserPaneModel(
        paneId: data.id(7), machineId: "screenshot", machineName: "Studio Mac", initialURL: "http://localhost:3000",
        client: environment.machines.client(for: data.machineID), resolveBaseURL: { nil }
      )
      if ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"] == "browser" {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        browser.adoptPopup(configuration: configuration).loadHTMLString(
          AppStoreScreenshotPage.html, baseURL: BrowserPaneModel.navigationURL("http://localhost:3000")
        )
      }
      self.environment = environment
      self.controller = controller
      self.browser = browser
    }
  }
#endif
