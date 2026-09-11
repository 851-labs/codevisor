#if DEBUG
  import Foundation
  import SwiftUI

  /// A populated sidebar for previews and design review. Debug builds
  /// launched with `CODEVISOR_SIDEBAR_SAMPLE=1` render it in place of the
  /// fleet, so the layout can be judged without pairing a machine and
  /// opening a dozen tabs by hand.
  enum HomeSidebarSampleData {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["CODEVISOR_SIDEBAR_SAMPLE"] == "1"
    }

    /// Stateful fixture: the production reorder callback updates the same
    /// section input that a saved workspace order would produce.
    struct Sidebar: View {
      @State private var sections = HomeSidebarSampleData.sections

      var body: some View {
        HomeSidebarList(
          sections: sections,
          actions: HomeSidebarActions(reorder: { ids in
            let byID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
            sections = ids.compactMap { byID[$0] }
          }),
          refresh: {}
        )
        .accessibilityIdentifier("sample-sidebar")
        .accessibilityValue(sections.map(\.name).joined(separator: ","))
      }
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
