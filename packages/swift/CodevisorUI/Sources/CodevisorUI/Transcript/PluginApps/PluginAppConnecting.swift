import CodevisorCore
import Foundation
import TranscriptKit

@MainActor
public protocol PluginAppConnecting {
  var canOpenFullscreen: Bool { get }
  func launch(_ app: CodevisorExecutionApp) async throws -> PluginAppLaunch
  func baseURL(for app: CodevisorExecutionApp) async -> URL?
  func subject(for app: CodevisorExecutionApp) async throws -> PluginModerationSubject?
  func openFullscreen(_ app: CodevisorExecutionApp) -> Bool
  func sendMessage(_ text: String, from app: CodevisorExecutionApp)
}
