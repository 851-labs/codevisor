#if DEBUG
  import Foundation

  /// A populated sidebar for previews and design review. Debug builds
  /// launched with `CODEVISOR_SIDEBAR_SAMPLE=1` render it in place of the
  /// fleet, so the layout can be judged without pairing a machine and
  /// opening a dozen tabs by hand.
  enum HomeSidebarSampleData {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["CODEVISOR_SIDEBAR_SAMPLE"] == "1"
    }

    private static let studio = "sample-studio"
    private static let linux = "sample-linux"

    static let sections: [HomeSidebarSection] = [
      HomeSidebarSection(
        id: UUID(),
        serverId: studio,
        name: "codevisor",
        machineName: "Studio Mac",
        anchorSessionId: UUID(),
        status: .inProgress,
        rows: [
          row(
            "Fix onboarding crash", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"), status: .inProgress),
          row(
            "Add dark mode support",
            .chat(harnessId: "codex", fallbackSymbolName: "chevron.left.forwardslash.chevron.right"), status: .unread),
          row("Terminal 1", .terminal(isAgentOwned: false)),
          row("bun run dev", .terminal(isAgentOwned: true)),
          row("Codevisor — localhost:3000", .browser(favicon: nil)),
          row("New Tab", .newTab),
        ]
      ),
      HomeSidebarSection(
        id: UUID(),
        serverId: studio,
        name: "landing-refresh",
        machineName: "Studio Mac",
        anchorSessionId: UUID(),
        status: .actionRequired,
        rows: [
          row(
            "Refresh landing page copy", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"),
            status: .actionRequired),
          row(
            "Lighthouse audit follow-ups",
            .chat(harnessId: "codex", fallbackSymbolName: "chevron.left.forwardslash.chevron.right")),
          row("Scratchpad", .plugin(pluginId: "851-labs.scratchpad", paneType: "scratchpad")),
          row("README.md", .document),
        ]
      ),
      HomeSidebarSection(
        id: UUID(),
        serverId: linux,
        name: "api",
        machineName: "Linux Box",
        anchorSessionId: UUID(),
        status: .error,
        rows: [
          row("Migrate sessions table", .chat(harnessId: "claude-code", fallbackSymbolName: "sparkle"), status: .error),
          row("Terminal 2", .terminal(isAgentOwned: false)),
        ]
      ),
      HomeSidebarSection(
        id: UUID(),
        serverId: linux,
        name: "scratch",
        machineName: "Linux Box",
        anchorSessionId: UUID(),
        status: .idle,
        rows: [row("New Tab", .newTab)]
      ),
    ]

    private static func row(
      _ title: String,
      _ icon: HomeSidebarTabRow.Icon,
      status: HomeSessionStatus = .idle
    ) -> HomeSidebarTabRow {
      HomeSidebarTabRow(
        id: UUID(),
        title: title,
        icon: icon,
        status: status,
        chatSessionId: nil,
        renamableTabId: UUID()
      )
    }
  }
#endif
