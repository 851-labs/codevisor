#if DEBUG
  import ACPKit
  import CodevisorCore
  import CodevisorTheming
  import Foundation
  import SwiftUI

  /// Offline inputs for the production views. Never compiled into release builds.
  enum AppStoreScreenshotData {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["CODEVISOR_APP_STORE_SCREENSHOTS"] == "1"
    }

    static var colorScheme: ColorScheme {
      ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_APPEARANCE"] == "dark" ? .dark : .light
    }

    @MainActor
    static func makeEnvironment() -> AppEnvironment {
      let environment = AppEnvironment.preview(
        seedProjects: [project], seedSessions: [session],
        seedMachines: [
          CodevisorMachine(
            id: machineID, name: "Studio Mac", baseURL: URL(string: "https://screenshots.invalid")!, kind: "remote")
        ], seedCapabilities: capabilities
      )
      environment.theme.setMode(colorScheme == .dark ? .dark : .light)
      environment.composerDefaults.rememberNewWorkspaceServer(serverId: machineID)
      environment.composerDefaults.rememberNewWorkspaceProject(serverId: machineID, projectId: projectID)
      environment.composerDefaults.rememberHarnessSelection(serverId: machineID, harnessId: "claude-code")
      environment.configCache.store(capabilities, forServer: machineID)
      return environment
    }

    @MainActor
    static func makeController() -> SessionController {
      SessionController.preview(
        project: project, model: .preview(conversation: conversation()),
        harnesses: SessionController.previewHarnesses.filter { $0.id == "codex" }
      )
    }

    static let projectID = id(1)
    static let machineID = "screenshot-studio"
    static let sessionID = id(2)
    static let paneID = id(3)
    static let assistantID = id(4)
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let title = "Build a focus timer"
    static let project = Project(
      id: projectID, serverId: machineID, name: "daylight", createdAt: date,
      locations: [
        ProjectLocation(id: "daylight", projectId: projectID, serverId: machineID, folderPath: "/projects/daylight")
      ]
    )
    static let session = ChatSession(
      id: sessionID, projectId: projectID, serverId: machineID, harnessId: "codex",
      agentSessionId: "screenshot-session",
      title: title, createdAt: date, updatedAt: date
    )

    static func id(_ value: Int) -> UUID {
      UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static let capabilities = [
      ServerHarnessCapability(
        harness: SessionController.previewHarnesses[0],
        modes: nil,
        configOptions: [
          SessionConfigOption(
            id: "model", name: "Model", category: "model", currentValue: "claude-sonnet-4-6",
            options: [SessionConfigSelectOption(value: "claude-sonnet-4-6", name: "Sonnet 4.6")]
          )
        ]
      )
    ]

    static func conversation() -> [ConversationItem] {
      var turn = AssistantTurn(
        isGenerating: false, stopReason: .endTurn, startedAt: date,
        endedAt: date.addingTimeInterval(42)
      )
      TranscriptReducer.apply(
        .toolCall(
          ToolCall(
            toolCallId: "focus-timer", title: "Edited FocusTimer.tsx", kind: .edit, status: .completed,
            content: [.diff(path: "src/FocusTimer.tsx", oldText: oldCode, newText: newCode)]
          )), to: &turn
      )
      TranscriptReducer.apply(
        .agentMessageChunk(
          .text(
            """
            The focus timer is ready to try.

            ### A little more focus
            Start a **25-minute session**, take a short break, and pick up where you left off.

            - Pause and resume without resetting
            - See your progress as the timer counts down
            - Get a gentle reminder when it’s time to rest

            ### Ready for your phone
            The layout adapts to smaller screens, with large controls and support for dark mode.

            All **12 tests pass**. The preview is running at **localhost:3000**.
            """
          )), to: &turn)
      return [
        .user(
          UserMessage(
            id: id(5),
            text: "Add a focus timer to Daylight. Keep it simple, make it work on mobile, and run the tests.")),
        .assistant(AssistantMessage(id: assistantID, turn: turn)),
      ]
    }

    static let oldCode = """
      export function FocusTimer() {
        const timer = useTimer(1500);
        return (
          <Timer value={timer.seconds}>
            <Button onClick={timer.reset}>
              Reset
            </Button>
          </Timer>
        );
      }
      """
    static let newCode = """
      export function FocusTimer() {
        const timer = useTimer(1500);
        const label = timer.running
          ? "Pause" : "Start focus";
        return (
          <Timer value={timer.seconds}>
            <Button onClick={timer.toggle}>
              {label}
            </Button>
          </Timer>
        );
      }
      """

    static let sections: [ScreenshotSidebarSection] = [
      ScreenshotSidebarSection(
        id: id(10), serverId: "studio", name: "daylight", machineName: "Studio Mac",
        anchorSessionId: sessionID, status: .unread,
        rows: [
          row(11, title, .chat(harnessId: "codex", fallbackSymbolName: "sparkle"), status: .unread),
          row(12, "Polish the mobile layout", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle")),
          row(13, "Daylight — localhost:3000", .browser(favicon: nil)),
          row(14, "Development server", .terminal(isAgentOwned: false)),
        ]
      ),
      ScreenshotSidebarSection(
        id: id(20), serverId: "studio", name: "portfolio", machineName: "Studio Mac",
        anchorSessionId: id(21), status: .inProgress,
        rows: [
          row(
            22, "Refresh the home page", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"),
            status: .inProgress),
          row(23, "Add project highlights", .chat(harnessId: "codex", fallbackSymbolName: "sparkle")),
          row(24, "README.md", .document),
        ]
      ),
      ScreenshotSidebarSection(
        id: id(30), serverId: "linux", name: "api", machineName: "Linux Server",
        anchorSessionId: id(31), status: .idle,
        rows: [
          row(32, "Add search to the API", .chat(harnessId: "codex", fallbackSymbolName: "sparkle")),
          row(33, "Review the test coverage", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle")),
          row(34, "Terminal", .terminal(isAgentOwned: false)),
        ]
      ),
    ]

    private static func row(
      _ value: Int, _ title: String, _ icon: ScreenshotSidebarTabRow.Icon, status: ScreenshotSessionStatus = .idle
    ) -> ScreenshotSidebarTabRow {
      ScreenshotSidebarTabRow(
        id: id(value), title: title, icon: icon, status: status, chatSessionId: nil, renamableTabId: id(value))
    }
  }

  enum ScreenshotSessionStatus: Int { case idle, unread, inProgress }

  struct ScreenshotSidebarSection: Identifiable {
    let id: UUID
    let serverId: String
    let name: String
    let machineName: String?
    let anchorSessionId: UUID
    let status: ScreenshotSessionStatus
    let rows: [ScreenshotSidebarTabRow]
  }

  struct ScreenshotSidebarTabRow: Identifiable {
    enum Icon {
      case chat(harnessId: String, fallbackSymbolName: String)
      case browser(favicon: String?)
      case terminal(isAgentOwned: Bool)
      case document
    }
    let id: UUID
    let title: String
    let icon: Icon
    let status: ScreenshotSessionStatus
    let chatSessionId: UUID?
    let renamableTabId: UUID?
  }
#endif
