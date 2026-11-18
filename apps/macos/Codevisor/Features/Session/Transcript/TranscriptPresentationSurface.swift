import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import TranscriptKit

@MainActor
final class TranscriptPresentationSurface {
  let textAnimationVisibility = StreamingTextAnimationVisibility(initiallyVisible: false)
  let textAnimationRegistry = StreamingTextAnimationRegistry()
  let findModel = TranscriptFindModel()
  let projection = TranscriptSettledProjection()
  let activeProjection = ActiveTranscriptProjection()
  let workedRowsVisibility = TranscriptWorkedRowsVisibilityCache()
  let composer = TranscriptComposerMetrics()
  let presentation: ChatPresentationState

  private weak var controller: SessionController?
  private var retainedScrollView: VirtualizedTranscriptScrollView?
  private var visibilityOwners: Set<UUID> = []

  init(controller: SessionController) {
    self.controller = controller
    presentation = ChatPresentationState(scrollState: controller.scrollState)
  }

  var existingScrollView: VirtualizedTranscriptScrollView? { retainedScrollView }
  var isWarm: Bool { retainedScrollView?.isInitialPresentationReady == true }
  var isAttachedToWindow: Bool {
    guard let retainedScrollView else { return false }

    return retainedScrollView.window != nil && !retainedScrollView.isHidden
  }

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

  func isPresented(by owner: UUID) -> Bool {
    visibilityOwners.contains(owner)
  }

  func disappear(owner: UUID) {
    visibilityOwners.remove(owner)
    if visibilityOwners.isEmpty {
      textAnimationVisibility.disappear()
    }
  }

  func prepareForEviction() {
    guard let scrollView = retainedScrollView, !isAttachedToWindow else { return }
    findModel.dismiss()
    retainedScrollView = nil
    scrollView.prepareForDismantle()
    scrollView.removeFromSuperview()
    visibilityOwners.removeAll()
    textAnimationVisibility.disappear()
    presentation.forgetMount()
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

  func remove(_ key: Key) {
    cache.remove(key)
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
