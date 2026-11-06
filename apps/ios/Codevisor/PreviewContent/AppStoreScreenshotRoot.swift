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
        } else if scene == "projects" || scene == "new-chat" || scene == "bots" {
          HomeView()
        } else if scene == "bot-conversation" {
          HomeView(initialRoute: featuredBot)
        } else if scene == "mascot-editor", let options = fixture.mascotOptions {
          if UIDevice.current.userInterfaceIdiom == .pad {
            HomeView(initialRoute: featuredBot)
              .sheet(isPresented: .constant(true)) { mascotEditor(options) }
          } else {
            mascotEditor(options)
          }
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

    private func mascotEditor(_ options: ServerBotMascotOptions) -> some View {
      BotMascotEditorScreen(
        mascot: DemoBots.featured.mascot, options: options,
        serverId: DemoModels.machineId(DemoBots.featured.machine), category: .headwear, onSave: { _ in })
    }

    private var featuredBot: HomeRoute {
      .bot(
        serverId: DemoModels.machineId(DemoBots.featured.machine), botId: DemoBots.botId(DemoBots.featured))
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
    private(set) var mascotOptions: ServerBotMascotOptions?

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
      ClientPreferences.shared.set(sidebarMode, forKey: SidebarMode.preferenceKey)
      ClientPreferences.shared.set(AIDataSharingConsent.currentVersion, forKey: AIDataSharingConsent.preferenceKey)
      ClientPreferences.shared.set(true, forKey: "ios.onboarding.dismissed")
    }

    private var sidebarMode: SidebarMode {
      let scene = ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SCENE"]
      return ["bots", "bot-conversation", "mascot-editor"].contains(scene) ? .chat : .code
    }

    func prepare() async {
      await DemoEnvironment.connect(environment)
      registerFeaturedBot()
      mascotOptions = try? await DemoServerClient(machine: DemoBots.featured.machine).botMascotOptions()
      isReady = true
    }

    private func registerFeaturedBot() {
      let bot = DemoBots.featured
      let serverId = DemoModels.machineId(bot.machine)
      guard let session = environment.projectList.session(DemoBots.sessionId(bot), serverId: serverId),
        let project = environment.projectList.projects.first(where: {
          $0.serverId == serverId && $0.id == session.projectId
        })
      else { return }
      let model = SessionModel(
        serverTransport: ServerSessionTransport(client: DemoServerClient(machine: bot.machine), sessionId: session.id),
        sessionId: session.agentSessionId ?? session.id.uuidString)
      let controller = SessionController.preview(
        project: project, model: model,
        harnesses: SessionController.previewHarnesses.filter { $0.id == session.harnessId })
      ChatControllerCache.shared.register(controller, for: session, environment: environment)
    }
  }
#endif
