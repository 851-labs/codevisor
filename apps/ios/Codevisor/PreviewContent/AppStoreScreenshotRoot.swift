#if DEBUG
  import CodevisorCore
  import CodevisorUI
  import Combine
  import SwiftUI
  import WebKit

  struct AppStoreScreenshotRoot: View {
    private let scene = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"] ?? "projects"
    @StateObject private var fixture = AppStoreScreenshotFixture()
    @State private var path = ["detail"]

    var body: some View {
      Group {
        if !fixture.isReady {
          Color.clear
        } else if scene == "projects" || scene == "new-chat" {
          HomeView()
        } else if scene == "conversation", UIDevice.current.userInterfaceIdiom == .pad {
          HomeView(initialRoute: featuredWorkspace)
        } else {
          NavigationStack(path: $path) {
            Color.clear
              .navigationDestination(for: String.self) { _ in
                if scene == "browser" {
                  BrowserPaneView(model: fixture.browser)
                    .navigationTitle(DemoWorld.featuredProject.name)
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
      .task {
        await fixture.prepare()
        announceReady()
      }
    }

    private func announceReady() {
      guard let path = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_READY_FILE"] else { return }
      try? "ready".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private var featuredWorkspace: HomeRoute {
      .workspace(
        serverId: AppStoreScreenshotData.machineID, workspaceId: DemoModels.featuredWorkspaceId,
        anchorSessionId: AppStoreScreenshotData.sessionID, preferredChatSessionId: nil)
    }
  }

  @MainActor
  private final class AppStoreScreenshotFixture: ObservableObject {
    let environment: AppEnvironment
    let controller: SessionController
    let browser: BrowserPaneModel
    @Published private(set) var isReady = false

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
          sessionId: data.sessionID, initialName: DemoWorld.featuredChat.title, serverId: data.machineID,
          projectId: data.projectID, rootDirectory: DemoWorld.featuredProject.folderPath,
          assignedWorkspaceId: DemoModels.featuredWorkspaceId
        ), legacyGroups: environment.paneGroups)
      ChatControllerCache.shared.register(controller, for: data.session, environment: environment)
      let browser = BrowserPaneModel(
        paneId: data.browserPaneID, machineId: data.machineID, machineName: data.machineName,
        initialURL: DemoWorld.previewURL,
        client: environment.machines.client(for: data.machineID), resolveBaseURL: { nil }
      )
      if ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"] == "browser" {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        browser.adoptPopup(configuration: configuration).loadHTMLString(
          AppStoreScreenshotPage.html, baseURL: BrowserPaneModel.navigationURL(DemoWorld.previewURL)
        )
      }
      self.environment = environment
      self.controller = controller
      self.browser = browser
      ClientPreferences.shared.set(SidebarGrouping.machine, forKey: SidebarGrouping.preferenceKey)
      ClientPreferences.shared.set(AIDataSharingConsent.currentVersion, forKey: AIDataSharingConsent.preferenceKey)
      ClientPreferences.shared.set(true, forKey: "ios.onboarding.dismissed")
    }

    func prepare() async {
      await DemoEnvironment.connect(environment)
      isReady = true
    }
  }
#endif
