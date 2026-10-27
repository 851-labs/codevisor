#if DEBUG
  import AppKit
  import CodevisorCore
  import CodevisorUI
  import SwiftUI

  struct BentoCard {
    enum DetailScroll: Equatable {
      case top
      case end
      case endRevealing(CGFloat)
    }

    enum Presentation: Equatable {
      case inline
      case sheet
      case window(height: CGFloat, title: String, scroll: DetailScroll = .top)
    }

    let name: String
    let width: CGFloat
    var section: Int?
    var presentation = Presentation.inline
    var prepare: @MainActor (AppEnvironment) -> Void = { _ in }
    var settle = Duration.milliseconds(1500)
    let content: @MainActor () -> AnyView

    static let all: [BentoCard] = [
      BentoCard(name: "mcp-machines", width: 440) { AnyView(BentoMcpSection(title: "MCP Servers", builtIn: false)) },
      BentoCard(name: "built-in-tools", width: 440) {
        AnyView(BentoMcpSection(title: "Built-in Tools", builtIn: true))
      },
      BentoCard(name: "accounts", width: 360) {
        AnyView(
          HarnessAuthenticationView(harness: DemoServerRecords.claudeCode, onChange: { _ in }, showsHeader: false))
      },
      BentoCard(name: "sounds", width: 420, section: 2) { AnyView(NotificationsSettingsView()) },
      BentoCard(name: "updates", width: 480) { AnyView(UpdateCenterView()) },
      BentoCard(
        name: "settings-updates-window", width: 780,
        presentation: .window(height: 560, title: SettingsTab.updates.title)
      ) {
        SettingsRouter.shared.selectedTab = .updates
        return AnyView(SettingsView().themedRoot())
      },
      BentoCard(
        name: "settings-sounds-window", width: 780,
        presentation: .window(height: 560, title: SettingsTab.notifications.title, scroll: .end)
      ) {
        SettingsRouter.shared.selectedTab = .notifications
        return AnyView(SettingsView().themedRoot())
      },
      BentoCard(
        name: "settings-plugins-window", width: 780,
        presentation: .window(
          height: 560, title: SettingsTab.plugins.title, scroll: .endRevealing(mcpServersAndLinearHeight))
      ) {
        SettingsRouter.shared.selectedTab = .plugins
        return AnyView(SettingsView().themedRoot())
      },
      BentoCard(
        name: "settings-accounts-window", width: 780,
        presentation: .window(height: 560, title: SettingsTab.agents.title),
        prepare: DemoEnvironment.seedHarnessFleet
      ) {
        SettingsRouter.shared.showHarnessAccounts(machineId: CodevisorMachine.local.id, harnessId: "claude-code")
        return AnyView(SettingsView().themedRoot())
      },
      BentoCard(name: "usage-limit", width: 420) { AnyView(usageLimitNotice.padding(20)) },
      BentoCard(name: "chrome-extension", width: 460) { AnyView(chromeExtensionCard.padding(20)) },
      BentoCard(name: "computer-use", width: 600, presentation: .sheet) {
        AnyView(ComputerUseSetupSheet(request: setupRequest(.computerUse), controller: sessionController()))
      },
      BentoCard(name: "simulator-settings", width: 340) { AnyView(BentoSimulatorSettings()) },
      BentoCard(
        name: "simulator-pane", width: 860, presentation: .window(height: 640, title: DemoWorld.featuredProject.name),
        settle: .seconds(4)
      ) {
        AnyView(BentoSimulatorPane())
      },
      BentoCard(name: "ghostty-terminal", width: 620, settle: .seconds(5)) {
        AnyView(
          BentoTerminal(command: "bun run dev")
            .frame(height: 230)
            .background(Color(nsColor: .windowBackgroundColor)))
      },
      BentoCard(name: "inspector-machine", width: inspectorWidth) {
        AnyView(
          WorkspaceInspectorMachineSection(
            stats: DemoServerRecords.machineStats(on: DemoWorld.thisMac), isExpanded: .constant(true)
          ).padding(.vertical, 10))
      },
      BentoCard(name: "inspector-usage", width: inspectorWidth) {
        AnyView(
          WorkspaceInspectorUsageSection(limits: DemoServerRecords.usageLimits, isExpanded: .constant(true))
            .padding(.vertical, 10))
      },
      BentoCard(name: "inspector-context", width: inspectorWidth) {
        AnyView(
          WorkspaceInspectorContextSection(
            context: DemoServerRecords.sessionContext, usage: nil, isExpanded: .constant(true)
          ).padding(.vertical, 10))
      },
    ]

    private static let inspectorWidth: CGFloat = 300

    private static let mcpServersAndLinearHeight: CGFloat = 215

    @MainActor
    private static var usageLimitNotice: some View {
      UsageLimitNotice(
        autoResume: SessionAutoResume(resumesAt: usageLimitReset), inBotConversation: false,
        switchAccount: {},
        cancelAutoResume: {})
    }

    @MainActor
    private static var chromeExtensionCard: some View {
      TranscriptSetupRequestCard(
        request: setupRequest(.chromeExtension), inBotConversation: false, handoffMachineName: nil,
        chromeSetup: .webStore(hasOldCopy: false), icon: Image(nsImage: NSApp.applicationIconImage),
        onSetUp: {}, onDecline: {})
    }

    private static let usageLimitResetDelay = DateComponents(hour: 2)

    private static var usageLimitReset: Date? {
      Calendar.current.date(byAdding: usageLimitResetDelay, to: DemoWorld.now)
    }

    private static func setupRequest(_ kind: TranscriptSetupRequest.Kind) -> TranscriptSetupRequest {
      TranscriptSetupRequest(id: "bento-\(kind)", kind: kind, state: .pending)
    }

    @MainActor
    private static func sessionController() -> SessionController {
      let project = DemoWorld.projects[0]
      return SessionController(
        project: Project.fromFolder(URL(fileURLWithPath: project.folderPath)),
        configCache: ConfigOptionCache(store: InMemoryStore()),
        serverClient: DemoServerClient(machine: project.machine))
    }
  }
#endif
