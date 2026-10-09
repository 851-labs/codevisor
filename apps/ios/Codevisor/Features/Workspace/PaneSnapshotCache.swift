import CodevisorUI
import SwiftUI
import UIKit

/// The last look of each tab, for the tab overview's tiles, as Safari keeps
/// them: captured when the overview opens over a tab, kept in memory, and
/// written to Caches so a relaunch paints the grid before any pane
/// reconnects. Purely a picture; losing it costs nothing but the preview.
@MainActor
@Observable
final class PaneSnapshotCache {
  static let shared = PaneSnapshotCache()

  private(set) var images: [UUID: UIImage] = [:]
  @ObservationIgnored private var attempted: Set<UUID> = []
  @ObservationIgnored private let directory: URL

  init(
    directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tab Previews", isDirectory: true)
  ) {
    self.directory = directory
  }

  func image(for paneId: UUID) -> UIImage? { images[paneId] }

  /// Reads the persisted previews of `paneIds` that aren't in memory, once
  /// per run each.
  func loadPersisted(_ paneIds: [UUID]) async {
    let missing = paneIds.filter { images[$0] == nil && !attempted.contains($0) }
    guard !missing.isEmpty else { return }
    attempted.formUnion(missing)
    let directory = directory
    let loaded = await Task.detached(priority: .utility) {
      missing.compactMap { id -> (UUID, Data)? in
        (try? Data(contentsOf: directory.appendingPathComponent(id.uuidString))).map { (id, $0) }
      }
    }.value
    for (id, data) in loaded where images[id] == nil {
      images[id] = UIImage(data: data)
    }
  }

  /// Renders `frame` (window coordinates) of the key window as the pane's
  /// preview.
  @discardableResult
  func capture(paneId: UUID, frame: CGRect) -> UIImage? {
    guard frame.width > 1, frame.height > 1, let window = Self.keyWindow else { return nil }
    let format = UIGraphicsImageRendererFormat()
    // Tiles are a fraction of the screen; 2x is sharp there and half the
    // memory of a 3x render.
    format.scale = min(2, window.traitCollection.displayScale)
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { _ in
      window.drawHierarchy(
        in: window.bounds.offsetBy(dx: -frame.minX, dy: -frame.minY), afterScreenUpdates: false)
    }
    images[paneId] = image
    attempted.insert(paneId)
    let url = directory.appendingPathComponent(paneId.uuidString)
    let directory = directory
    Task.detached(priority: .utility) {
      guard let data = image.jpegData(compressionQuality: 0.8) else { return }
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: url, options: .atomic)
    }
    return image
  }

  func remove(paneId: UUID) {
    images[paneId] = nil
    let url = directory.appendingPathComponent(paneId.uuidString)
    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
  }

  private static var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
  }
}
