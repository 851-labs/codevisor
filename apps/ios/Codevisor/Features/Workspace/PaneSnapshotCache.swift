import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

@MainActor
@Observable
final class PaneSnapshotCache {
  static let shared = PaneSnapshotCache()
  private(set) var images: [WorkspacePanePreviewKey: UIImage] = [:]
  @ObservationIgnored private var attemptedDiskLoads: Set<WorkspacePanePreviewKey> = []
  @ObservationIgnored private let diskStore: WorkspacePanePreviewDiskStore
  /// The visible chat pane's composer-stack height, written by the pane
  /// body so captures can crop it. (Plain storage, not a SwiftUI
  /// preference: preferences fed back into navigation state cancel
  /// in-flight push transitions.)
  var activeBottomChrome: CGFloat = 0

  init(
    diskStore: WorkspacePanePreviewDiskStore = WorkspacePanePreviewDiskStore(
      directory: CodevisorAppVariant.applicationSupportURL()
        .appendingPathComponent("Pane Previews", isDirectory: true)
    )
  ) {
    self.diskStore = diskStore
  }

  func image(for paneId: UUID, in workspaceId: UUID) -> UIImage? {
    images[WorkspacePanePreviewKey(workspaceId: workspaceId, paneId: paneId)]
  }

  /// Loads durable stale images without waiting for any pane controller or
  /// server. Missing entries are remembered for this run so ordinary view
  /// updates do not repeatedly touch disk.
  func loadPersistedPreviews(workspaceId: UUID, paneIds: [UUID]) async {
    let keys = paneIds.map {
      WorkspacePanePreviewKey(workspaceId: workspaceId, paneId: $0)
    }.filter { key in
      images[key] == nil && !attemptedDiskLoads.contains(key)
    }
    guard !keys.isEmpty else { return }
    attemptedDiskLoads.formUnion(keys)

    let bytes = await diskStore.data(for: keys)
    guard !Task.isCancelled else { return }
    for key in keys {
      guard let data = bytes[key] else { continue }
      if let image = UIImage(data: data) {
        images[key] = image
      } else {
        // A truncated or unsupported cache file is disposable. Never
        // let it poison future launches or block the fallback zoom.
        try? await diskStore.remove(key)
      }
    }
  }

  func store(
    _ image: UIImage,
    for paneId: UUID,
    in workspaceId: UUID,
    persist: Bool = true
  ) {
    let key = WorkspacePanePreviewKey(
      workspaceId: workspaceId,
      paneId: paneId
    )
    images[key] = image
    attemptedDiskLoads.insert(key)
    guard persist else { return }

    let diskStore = diskStore
    Task {
      let data = await Task.detached(priority: .utility) {
        image.pngData()
      }.value
      guard let data else { return }
      try? await diskStore.save(data, for: key)
    }
  }

  func remove(paneId: UUID, from workspaceId: UUID) {
    let key = WorkspacePanePreviewKey(
      workspaceId: workspaceId,
      paneId: paneId
    )
    images[key] = nil
    attemptedDiskLoads.insert(key)
    let diskStore = diskStore
    Task { try? await diskStore.remove(key) }
  }

  /// `bottomChrome` is the height of pane-owned chrome above the safe area
  /// (the chat composer) to exclude, so previews show only content.
  @discardableResult
  func captureKeyWindow(
    for paneId: UUID,
    in workspaceId: UUID,
    bottomChrome: CGFloat = 0
  ) -> PaneTransitionSnapshot? {
    guard let window = activeWindow else { return nil }
    let contentFrame = contentFrame(in: window, bottomChrome: bottomChrome)
    let transitionView = window.resizableSnapshotView(
      from: contentFrame,
      afterScreenUpdates: false,
      withCapInsets: .zero
    )
    let backdropView = window.snapshotView(afterScreenUpdates: false)

    // Card previews need only card-quality pixels. Rendering the clipped
    // content at 2x avoids the previous 3x full-window allocation while
    // remaining sharp in the two-column grid.
    let format = UIGraphicsImageRendererFormat()
    format.scale = min(2, window.screen.scale)
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: contentFrame.size, format: format)
    let image = renderer.image { _ in
      window.drawHierarchy(
        in: window.bounds.offsetBy(
          dx: -contentFrame.minX,
          dy: -contentFrame.minY
        ),
        afterScreenUpdates: false
      )
    }
    store(image, for: paneId, in: workspaceId)
    return PaneTransitionSnapshot(
      image: image,
      contentFrame: contentFrame,
      transitionView: transitionView,
      backdropView: backdropView
    )
  }

  func transitionSnapshot(
    for paneId: UUID,
    in workspaceId: UUID,
    bottomChrome: CGFloat = 0
  ) -> PaneTransitionSnapshot? {
    guard let window = activeWindow else { return nil }
    return PaneTransitionSnapshot(
      image: image(for: paneId, in: workspaceId),
      contentFrame: contentFrame(in: window, bottomChrome: bottomChrome),
      transitionView: nil,
      backdropView: nil
    )
  }

  private var activeWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }
  }

  private func contentFrame(in window: UIWindow, bottomChrome: CGFloat) -> CGRect {
    // Read the actual bar geometry rather than assuming the historical
    // 44pt height. Current iOS navigation chrome is taller, and even a
    // small mismatch is conspicuous when the zoom begins.
    let navigationBottom =
      visibleNavigationBarBottom(in: window)
      ?? window.safeAreaInsets.top + 44
    let bottomInset =
      bottomChrome > 0
      ? bottomChrome + window.safeAreaInsets.bottom
      : 0
    return CGRect(
      x: window.bounds.minX,
      y: navigationBottom,
      width: window.bounds.width,
      height: max(1, window.bounds.maxY - navigationBottom - bottomInset)
    )
  }

  private func visibleNavigationBarBottom(in root: UIView) -> CGFloat? {
    var bottoms: [CGFloat] = []
    func visit(_ view: UIView) {
      if let bar = view as? UINavigationBar,
        !bar.isHidden,
        bar.alpha > 0.01,
        let window = bar.window
      {
        let frame = bar.convert(bar.bounds, to: window)
        if frame.height > 0, frame.intersects(window.bounds) {
          bottoms.append(frame.maxY)
        }
      }
      view.subviews.forEach(visit)
    }
    visit(root)
    return bottoms.max()
  }
}
