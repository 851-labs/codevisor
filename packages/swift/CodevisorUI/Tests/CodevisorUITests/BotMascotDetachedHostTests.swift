#if canImport(AppKit)
  import AppKit
  import CodevisorClient
  import CodevisorCore
  import Foundation
  import SwiftUI
  import Testing
  @testable import CodevisorUI

  @Suite("Bot mascot in a host without AppEnvironment")
  @MainActor
  struct BotMascotDetachedHostTests {
    enum Mascot: CaseIterable {
      case figure
      case rive
    }

    private static let slot: CGFloat = 26
    private static let mascot = ServerBotMascot(color: "tomato", hat: "beanie", eyewear: "goggles")
    private static let bot = Bot(
      serverId: "local",
      record: ServerBot(
        id: UUID().uuidString, serverId: "local", name: "Atlas", symbolName: "sparkles", harnessId: "claude-code",
        projectId: UUID().uuidString, sessionId: UUID().uuidString, workspaceId: UUID().uuidString,
        rootPath: "/bots/atlas", projects: [], isArchived: false, createdAt: "2026-10-27T00:00:00Z"))!

    @Test(
      "A mascot in a transcript row that left its window keeps its slot",
      arguments: Mascot.allCases)
    func rendersWithoutAppEnvironment(_ mascot: Mascot) {
      let host = NSHostingView(rootView: Self.view(mascot))
      let window = Self.window(containing: host)
      defer { window.close() }
      host.layoutSubtreeIfNeeded()

      host.removeFromSuperview()
      host.layoutSubtreeIfNeeded()

      #expect(host.fittingSize == CGSize(width: Self.slot, height: Self.slot))
    }

    private static func view(_ mascot: Mascot) -> AnyView {
      switch mascot {
      case .figure:
        AnyView(BotMascotFigure(bot: bot, mascot: Self.mascot, slot: slot))
      case .rive:
        AnyView(
          BotMascotRiveView(key: BotMascotStageKey(bot), mascot: Self.mascot)
            .frame(width: slot, height: slot))
      }
    }

    private static func window(containing host: NSView) -> NSWindow {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 120, height: 120),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView = NSView(frame: window.contentLayoutRect)
      window.contentView?.addSubview(host)
      return window
    }
  }
#endif
