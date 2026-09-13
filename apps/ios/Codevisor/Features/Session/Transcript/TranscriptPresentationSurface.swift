import CodevisorCore
import CodevisorUI
import Observation
import StreamMarkdown
import TranscriptKit
import UIKit

/// Owns the native row window independently of a SwiftUI navigation lifetime.
/// The container controller can go away while these measured views remain.
@MainActor
@Observable
final class TranscriptPresentationSurface {
  let textAnimationVisibility = StreamingTextAnimationVisibility(initiallyVisible: false)
  let textAnimationRegistry = StreamingTextAnimationRegistry()
  let disclosure = TranscriptDisclosureStore()
  private(set) var hasPresentedContent = false
  @ObservationIgnored private weak var sessionController: SessionController?
  @ObservationIgnored private var retainedController: TranscriptViewController?
  @ObservationIgnored private var visibilityOwners: Set<UUID> = []

  init(controller: SessionController) {
    sessionController = controller
  }

  var isAttached: Bool {
    retainedController?.parent != nil || !visibilityOwners.isEmpty
  }

  func matches(_ controller: SessionController) -> Bool {
    sessionController === controller
  }

  func ensureController() -> TranscriptViewController {
    if let retainedController { return retainedController }
    let controller = TranscriptViewController()
    retainedController = controller
    controller.onInitialPresentationReady = { [weak self, weak controller] in
      // UIKit can reveal from inside a SwiftUI update. Publish the loading
      // state after that transaction, and ignore a discarded surface's work.
      Task { @MainActor [weak self, weak controller] in
        guard let self, let controller, self.retainedController === controller else { return }
        self.hasPresentedContent = true
      }
    }
    return controller
  }

  func appear(owner: UUID) {
    let wasHidden = visibilityOwners.isEmpty
    visibilityOwners.insert(owner)
    if wasHidden {
      textAnimationVisibility.appear()
    }
  }

  func disappear(owner: UUID) {
    visibilityOwners.remove(owner)
    if visibilityOwners.isEmpty { textAnimationVisibility.disappear() }
  }

  func discard() {
    guard !isAttached else { return }
    retainedController?.prepareForDismantle()
    retainedController = nil
    hasPresentedContent = false
    textAnimationVisibility.disappear()
  }
}

@MainActor
final class TranscriptPresentationSurfaceCache {
  struct Key: Hashable {
    let paneID: UUID
    let isNewChat: Bool
  }

  static let shared = TranscriptPresentationSurfaceCache()
  private let cache = TranscriptPresentationCache<Key, TranscriptPresentationSurface>(
    detachedLimit: 3,
    isAttached: { $0.isAttached },
    discard: { $0.discard() }
  )
  private var trimTask: Task<Void, Never>?
  private var memoryObserver: NSObjectProtocol?

  init() {
    memoryObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.cache.trim(discardingAllDetached: true)
      }
    }
  }

  deinit {
    trimTask?.cancel()
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
  }

  func surface(for key: Key, controller: SessionController) -> TranscriptPresentationSurface {
    if let surface = cache.value(for: key), surface.matches(controller) {
      TranscriptPerformanceTrace.record("ios.surface", values: ["reused": 1, "entries": Double(cache.count)])
      return surface
    }
    TranscriptPerformanceTrace.record("ios.surface", values: ["reused": 0, "entries": Double(cache.count)])
    let surface = TranscriptPresentationSurface(controller: controller)
    cache.insert(surface, for: key)
    scheduleTrim(excluding: key)
    return surface
  }

  func remove(paneID: UUID) {
    cache.remove { $0.paneID == paneID }
  }

  func scheduleTrim(excluding key: Key? = nil) {
    trimTask?.cancel()
    trimTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      trimTask = nil
      cache.trim(excluding: key)
    }
  }
}
