import CoreGraphics
import Foundation
import TranscriptKit

@MainActor
public final class PluginAppInlineModelCache {
  public static let shared = PluginAppInlineModelCache()

  static let defaultCapacity = 6

  private let capacity: Int
  private let registry: PluginAppDisplayRegistry
  private var models: [String: PluginAppInlineModel] = [:]
  private var recency: [String] = []
  private var evictedHeights: [String: CGFloat] = [:]

  init(capacity: Int = PluginAppInlineModelCache.defaultCapacity, registry: PluginAppDisplayRegistry = .shared) {
    self.capacity = capacity
    self.registry = registry
  }

  func model(for app: CodevisorExecutionApp, chatMachineId: String) -> PluginAppInlineModel {
    let key = Self.key(app, chatMachineId: chatMachineId)
    touch(key)
    if let model = models[key] ?? registry.presentedModel(for: key) {
      models[key] = model
      return model
    }

    let model = PluginAppInlineModel(
      app: app, key: key, height: evictedHeights.removeValue(forKey: key), registry: registry)
    models[key] = model
    evictOverflow()
    return model
  }

  static func key(_ app: CodevisorExecutionApp, chatMachineId: String) -> String {
    "\(app.owningMachineId(fallback: chatMachineId))|\(app.viewId)"
  }

  private func touch(_ key: String) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }

  private func evictOverflow() {
    var overflow = recency.count - capacity
    for key in recency where overflow > 0 && registry.presentedModel(for: key) == nil {
      overflow -= 1
      recency.removeAll { $0 == key }
      let evicted = models.removeValue(forKey: key)
      evicted?.page.suspend(reason: "The chat no longer shows this app.")
      evictedHeights[key] = evicted?.page.height
    }
  }
}
