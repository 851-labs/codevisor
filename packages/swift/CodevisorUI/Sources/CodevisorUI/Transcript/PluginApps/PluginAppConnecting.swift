import CodevisorCore
import Foundation
import TranscriptKit

@MainActor
public protocol PluginAppConnecting {
  var fullscreen: PluginAppFullscreen { get }
  func launch(_ app: CodevisorExecutionApp) async throws -> PluginAppLaunch
  func baseURL(for app: CodevisorExecutionApp) async -> URL?
  func subject(for app: CodevisorExecutionApp) async throws -> PluginModerationSubject?
  func openFullscreen(_ app: CodevisorExecutionApp, in placement: PluginAppPanePlacement) -> PluginAppPanePlacement?
  func sendMessage(_ text: String, from app: CodevisorExecutionApp)
}

extension PluginAppConnecting {
  var canOpenFullscreen: Bool { fullscreen != .unavailable }
}
