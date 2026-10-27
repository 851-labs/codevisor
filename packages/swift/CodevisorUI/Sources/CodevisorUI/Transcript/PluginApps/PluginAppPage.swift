import CodevisorCore
import CoreGraphics
import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class PluginAppPage {
  public enum Phase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
  }

  public static let placeholderHeight: CGFloat = 240

  public let app: CodevisorExecutionApp
  public private(set) var phase: Phase = .idle
  public private(set) var height: CGFloat

  @ObservationIgnored var onMessage: ((PluginAppNativeMessage) -> Void)?
  @ObservationIgnored private var connection: (any PluginAppConnecting)?
  @ObservationIgnored private var controller: PluginAppWebController?
  @ObservationIgnored private var launch: PluginAppLaunch?
  @ObservationIgnored private var display: PluginAppDisplay?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var retriedUnauthorized = false
  @ObservationIgnored private let now: () -> Date

  init(app: CodevisorExecutionApp, height: CGFloat? = nil, now: @escaping () -> Date = Date.init) {
    self.app = app
    self.height = height ?? Self.placeholderHeight
    self.now = now
  }

  public var webController: PluginAppWebController? {
    guard phase == .loading || phase == .ready else { return nil }
    return controller
  }

  func show(display: PluginAppDisplay, connection: any PluginAppConnecting) {
    self.connection = connection
    let previous = self.display
    self.display = display
    guard controller != nil, phase != .idle else {
      reload()
      return
    }
    guard previous?.isDark != display.isDark else { return }

    applyTheme(display.theme)
  }

  func suspend() {
    task?.cancel()
    controller = nil
    phase = .idle
  }

  func retry() {
    reload()
  }

  func notifyDisplayMode(_ mode: PluginAppDisplayMode, requestId: String?) {
    display?.mode = mode
    guard let controller else { return }

    Task { await controller.notifyDisplayMode(mode, requestId: requestId) }
  }

  private func reload() {
    task?.cancel()
    task = Task { [weak self] in await self?.loadPage() }
  }

  private func applyTheme(_ theme: String) {
    guard let controller else { return }

    Task { [weak self] in
      guard await !controller.setTheme(theme) else { return }
      self?.reload()
    }
  }

  private func loadPage() async {
    guard let connection, let display else { return }

    phase = .loading
    do {
      let url = try await pageURL(connection, display: display)
      guard !Task.isCancelled else { return }
      ensureController().load(url)
    } catch {
      guard !Task.isCancelled else { return }
      phase = .failed(ErrorReporter.userFacingMessage(for: error))
    }
  }

  private func pageURL(_ connection: any PluginAppConnecting, display: PluginAppDisplay) async throws -> URL {
    let launch = try await freshLaunch(connection)
    guard let base = await connection.baseURL(for: app) else { throw PluginAppLoadError.relayUnavailable }
    guard let url = PluginAppViewURL.resolve(launchPath: launch.path, base: base, display: display) else {
      throw PluginAppLoadError.unusableAddress
    }
    return url
  }

  private func freshLaunch(_ connection: any PluginAppConnecting) async throws -> PluginAppLaunch {
    if let launch, launch.isFresh(at: now()) { return launch }

    let issued = try await connection.launch(app)
    launch = issued
    return issued
  }

  private func ensureController() -> PluginAppWebController {
    if let controller { return controller }

    let controller = PluginAppWebController()
    controller.onMessage = { [weak self] message in self?.receive(message) }
    controller.onLoaded = { [weak self] in self?.loaded() }
    controller.onFailed = { [weak self] failure in self?.failed(failure) }
    controller.onTerminated = { [weak self] in self?.reload() }
    self.controller = controller
    return controller
  }

  private func loaded() {
    retriedUnauthorized = false
    phase = .ready
  }

  private func failed(_ failure: PluginAppWebController.LoadFailure) {
    switch failure {
    case .unauthorized where !retriedUnauthorized:
      retriedUnauthorized = true
      launch = nil
      reload()
    case .unauthorized:
      phase = .failed("This app link has expired. Try again to reopen it.")
    case let .failed(message):
      phase = .failed(message)
    }
  }

  private func receive(_ message: PluginAppNativeMessage) {
    switch message {
    case let .size(height):
      self.height = height
    case let .openLink(url):
      PluginAppWebController.openExternally(url)
    case .message, .displayMode, .appModes:
      onMessage?(message)
    }
  }
}
