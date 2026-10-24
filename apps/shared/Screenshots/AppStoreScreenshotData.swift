#if DEBUG
  import ACPKit
  import CodevisorCore
  import Foundation
  import SwiftUI

  enum AppStoreScreenshotData {
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["CODEVISOR_APP_STORE_SCREENSHOTS"] == "1"
    }

    static var opensNewChat: Bool {
      isEnabled && ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_OPENS_NEW_CHAT"] == "1"
    }

    static var opensRunLocationMenu: Bool {
      isEnabled && ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_OPENS_RUN_LOCATION_MENU"] == "1"
    }

    static var showsInspector: Bool {
      isEnabled && ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_SHOWS_INSPECTOR"] == "1"
    }

    static var inspectorWidth: CGFloat? {
      guard isEnabled else { return nil }
      return ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_INSPECTOR_WIDTH"]
        .flatMap(Double.init).map { CGFloat($0) }
    }

    static var colorScheme: ColorScheme {
      ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_APPEARANCE"] == "dark" ? .dark : .light
    }

    @MainActor
    static func makeEnvironment() -> AppEnvironment {
      let environment = DemoEnvironment.make()
      DemoEnvironment.seedNavigation(environment)
      environment.composerDefaults.rememberNewWorkspaceServer(serverId: machineID)
      environment.composerDefaults.rememberNewWorkspaceProject(serverId: machineID, projectId: projectID)
      environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
        serverId: machineID, projectId: projectID, createsWorktree: true)
      environment.composerDefaults.rememberHarnessSelection(serverId: machineID, harnessId: session.harnessId)
      environment.composerDefaults.rememberConfigSelections(
        in: .newWorkspace(serverId: machineID), harnessId: session.harnessId,
        configValues: ["model": DemoWorld.featuredModel.id]
      )
      return environment
    }

    @MainActor
    static func makeController() -> SessionController {
      SessionController.preview(
        project: project, model: .preview(conversation: conversation()),
        harnesses: SessionController.previewHarnesses.filter { $0.id == session.harnessId }
      )
    }

    static let project = DemoModels.project(DemoWorld.featuredProject)
    static let session = DemoModels.featuredSession
    static let projectID = project.id
    static let machineID = project.serverId
    static let machineName = DemoWorld.featuredProject.machine.name
    static let sessionID = session.id
    static let paneID = id(3)
    static let assistantID = id(4)
    static let browserPaneID = id(7)
    static let date = DemoModels.date
    static let title = session.title

    static func id(_ value: Int) -> UUID { DemoModels.id(value) }

    static func conversation() -> [ConversationItem] {
      var turn = AssistantTurn(
        isGenerating: false, stopReason: .endTurn, startedAt: date, endedAt: date.addingTimeInterval(42)
      )
      TranscriptReducer.apply(
        .toolCall(
          ToolCall(
            toolCallId: "skin-tones", title: DemoConversation.editTitle, kind: .edit, status: .completed,
            content: [
              .diff(
                path: DemoConversation.editedFile, oldText: DemoConversation.before, newText: DemoConversation.after)
            ]
          )), to: &turn
      )
      TranscriptReducer.apply(.agentMessageChunk(.text(DemoConversation.reply)), to: &turn)
      return [
        .user(UserMessage(id: id(5), text: DemoConversation.prompt)),
        .assistant(AssistantMessage(id: assistantID, turn: turn)),
      ]
    }
  }
#endif
