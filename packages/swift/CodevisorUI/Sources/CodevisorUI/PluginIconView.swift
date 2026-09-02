import CodevisorCore
import SwiftUI

#if os(macOS)
  import AppKit
  private typealias PluginPlatformImage = NSImage
#else
  import UIKit
  private typealias PluginPlatformImage = UIImage
#endif

private actor PluginIconDataCache {
  static let shared = PluginIconDataCache()

  private struct Entry {
    let data: Data?
    let loadedAt: Date
  }

  private let successTTL: TimeInterval = 300
  private let failureTTL: TimeInterval = 30
  private var entriesByKey: [String: Entry] = [:]

  func data(
    for key: String,
    load: @Sendable () async throws -> Data
  ) async -> Data? {
    let now = Date()
    if let entry = entriesByKey[key] {
      let ttl = entry.data == nil ? failureTTL : successTTL
      if now.timeIntervalSince(entry.loadedAt) < ttl {
        return entry.data
      }
    }
    do {
      let data = try await load()
      entriesByKey[key] = Entry(data: data, loadedAt: now)
      return data
    } catch {
      entriesByKey[key] = Entry(data: nil, loadedAt: now)
      return nil
    }
  }
}

/// Plugin-supplied artwork for client chrome. The server normalizes SVG,
/// PNG, and WebP sources to PNG, so this view follows the same native raster
/// path on macOS and iOS. Missing or invalid artwork uses client-owned SF
/// Symbol fallback chrome.
public struct PluginIconView: View {
  private let pluginId: String
  private let paneType: String?
  private let iconPath: String?
  private let client: any CodevisorServerClienting
  private let cacheNamespace: String
  private let fallbackSystemName: String

  @State private var image: PluginPlatformImage?

  public init(
    pluginId: String,
    paneType: String? = nil,
    iconPath: String?,
    client: any CodevisorServerClienting,
    cacheNamespace: String,
    fallbackSystemName: String = "puzzlepiece.extension"
  ) {
    self.pluginId = pluginId
    self.paneType = paneType
    self.iconPath = iconPath
    self.client = client
    self.cacheNamespace = cacheNamespace
    self.fallbackSystemName = fallbackSystemName
  }

  private var cacheKey: String {
    [cacheNamespace, pluginId, paneType ?? "plugin", iconPath ?? "fallback"]
      .joined(separator: ":")
  }

  public var body: some View {
    Group {
      if let image {
        #if os(macOS)
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
        #else
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
        #endif
      } else {
        Image(systemName: fallbackSystemName)
      }
    }
    .task(id: cacheKey) {
      image = nil
      guard iconPath != nil else { return }
      let loaded = await PluginIconDataCache.shared.data(for: cacheKey) {
        try await client.pluginIcon(pluginId: pluginId, paneType: paneType).data
      }
      guard !Task.isCancelled, let loaded else { return }
      image = PluginPlatformImage(data: loaded)
    }
  }
}
