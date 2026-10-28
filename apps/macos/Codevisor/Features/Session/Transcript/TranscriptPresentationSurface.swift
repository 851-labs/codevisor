import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown

@MainActor
final class TranscriptPresentationSurface {
  let textAnimationVisibility = StreamingTextAnimationVisibility(initiallyVisible: false)
  let textAnimationRegistry = StreamingTextAnimationRegistry()
  let findModel = TranscriptFindModel()

  private weak var controller: SessionController?
  private var retainedScrollView: VirtualizedTranscriptScrollView?
  private var visibilityOwners: Set<UUID> = []
  private(set) var composerHeight: CGFloat = 96

  init(controller: SessionController) {
    self.controller = controller
  }

  var existingScrollView: VirtualizedTranscriptScrollView? { retainedScrollView }
  var isWarm: Bool { retainedScrollView?.isInitialPresentationReady == true }
  var isAttachedToWindow: Bool { retainedScrollView?.window != nil }

  func ensureScrollView() -> VirtualizedTranscriptScrollView {
    if let retainedScrollView { return retainedScrollView }
    let scrollView = VirtualizedTranscriptScrollView()
    retainedScrollView = scrollView
    scrollView.attachFindModel(findModel)
    return scrollView
  }

  func matches(controller: SessionController) -> Bool {
    self.controller === controller
  }

  func appear(owner: UUID) {
    let wasHidden = visibilityOwners.isEmpty
    visibilityOwners.insert(owner)
    if wasHidden {
      textAnimationRegistry.prepareForPresentation()
      textAnimationVisibility.appear()
    }
  }

  func disappear(owner: UUID) {
    visibilityOwners.remove(owner)
    if visibilityOwners.isEmpty {
      textAnimationVisibility.disappear()
    }
  }

  func updateComposerHeight(_ height: CGFloat) {
    composerHeight = height
  }

  func prepareForEviction() {
    guard let scrollView = retainedScrollView, scrollView.window == nil else { return }
    findModel.dismiss()
    retainedScrollView = nil
    scrollView.prepareForDismantle()
    scrollView.removeFromSuperview()
    visibilityOwners.removeAll()
    textAnimationVisibility.disappear()
  }
}

@MainActor
final class TranscriptPresentationSurfaceCache {
  struct Key: Hashable {
    let sessionID: UUID
    let paneID: UUID
  }

  private let cache: TranscriptPresentationCache<Key, TranscriptPresentationSurface>
  private var trimTask: Task<Void, Never>?

  init(maxDetachedSurfaceCount: Int = 6) {
    cache = TranscriptPresentationCache(
      detachedLimit: maxDetachedSurfaceCount,
      isAttached: { $0.isAttachedToWindow },
      discard: { surface in
        Task { @MainActor in
          await Task.yield()
          surface.prepareForEviction()
        }
      }
    )
  }

  func surface(
    for key: Key,
    controller: SessionController
  ) -> TranscriptPresentationSurface {
    if let surface = cache.value(for: key), surface.matches(controller: controller) {
      scheduleTrim(excluding: key)
      return surface
    }

    let surface = TranscriptPresentationSurface(controller: controller)
    cache.insert(surface, for: key)
    scheduleTrim(excluding: key)
    return surface
  }

  func remove(sessionID: UUID) {
    cache.remove { $0.sessionID == sessionID }
  }

  private func scheduleTrim(excluding protectedKey: Key) {
    trimTask?.cancel()
    trimTask = Task { @MainActor [weak self] in
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(16))
      guard !Task.isCancelled, let self else { return }
      trimTask = nil
      cache.trim(excluding: protectedKey)
    }
  }
}
