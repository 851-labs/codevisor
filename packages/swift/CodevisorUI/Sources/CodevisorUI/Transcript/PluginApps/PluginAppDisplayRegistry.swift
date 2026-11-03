import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class PluginAppDisplayRegistry {
  public static let shared = PluginAppDisplayRegistry()

  public private(set) var pip: PluginAppInlineModel?
  public private(set) var pipStartedAt: Date?
  private(set) var fullscreenKeys: Set<String> = []
  @ObservationIgnored private let now: () -> Date

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  func mode(for model: PluginAppInlineModel) -> PluginAppDisplayMode {
    if fullscreenKeys.contains(model.key) { return .fullscreen }
    if pip === model { return .pip }
    return .inline
  }

  public func pip(forChat chatSessionId: UUID) -> PluginAppInlineModel? {
    guard let pip, pip.chatSessionId == chatSessionId else { return nil }
    return pip
  }

  func startPip(_ model: PluginAppInlineModel) {
    let previous = pip
    pip = model
    pipStartedAt = now()
    guard let previous, previous !== model else { return }

    previous.page.notifyDisplayMode(.inline, requestId: nil)
  }

  func endPip(_ model: PluginAppInlineModel) {
    guard pip === model else { return }
    pip = nil
    pipStartedAt = nil
  }

  func beginFullscreen(_ key: String) {
    fullscreenKeys.insert(key)
    if let pip, pip.key == key { endPip(pip) }
  }

  func endFullscreen(_ key: String) {
    fullscreenKeys.remove(key)
  }

  func presentedModel(for key: String) -> PluginAppInlineModel? {
    guard let pip, pip.key == key else { return nil }
    return pip
  }
}
