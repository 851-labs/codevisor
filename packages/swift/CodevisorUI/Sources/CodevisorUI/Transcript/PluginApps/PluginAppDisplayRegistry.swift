import Foundation
import Observation

@MainActor
@Observable
public final class PluginAppDisplayRegistry {
  public static let shared = PluginAppDisplayRegistry()

  public private(set) var pip: PluginAppInlineModel?
  private(set) var fullscreenKeys: Set<String> = []

  func mode(for model: PluginAppInlineModel) -> PluginAppDisplayMode {
    if fullscreenKeys.contains(model.key) { return .fullscreen }
    if pip === model { return .pip }
    return .inline
  }

  func startPip(_ model: PluginAppInlineModel) {
    let previous = pip
    pip = model
    guard let previous, previous !== model else { return }

    previous.page.notifyDisplayMode(.inline, requestId: nil)
  }

  func endPip(_ model: PluginAppInlineModel) {
    guard pip === model else { return }
    pip = nil
  }

  func beginFullscreen(_ key: String) {
    fullscreenKeys.insert(key)
    if pip?.key == key { pip = nil }
  }

  func endFullscreen(_ key: String) {
    fullscreenKeys.remove(key)
  }

  func pipModel(for key: String) -> PluginAppInlineModel? {
    guard pip?.key == key else { return nil }
    return pip
  }
}
