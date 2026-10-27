import CodevisorCore
import Foundation
import TranscriptKit

enum PluginAppChatMessage {
  @MainActor
  static func send(
    _ text: String, from app: CodevisorExecutionApp, to sessionId: UUID?, client: any CodevisorServerClienting
  ) {
    guard let sessionId else { return }

    let attribution = UserMessageAttribution.app(viewId: app.viewId, plugin: app.serverName)
    Task {
      do {
        _ = try await client.promptSession(id: sessionId, text: text, attribution: attribution)
      } catch {
        Log.plugins.error(
          "app message from \(app.viewId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
