import Foundation

/// Remembers which semantic text streams have already been presented inside
/// one mounted transcript turn. The owner seeds streams that existed before
/// the turn view mounted; a stream first claimed afterward is genuinely new
/// live output and may animate its initial content.
///
/// The presentation deliberately lives above AppKit/UIKit text coordinators.
/// Native surfaces can be recreated by navigation, disclosure, virtualization,
/// or Markdown tail reclassification without making old text new again.
@MainActor
public final class StreamingTextAnimationPresentation {
  private var presentedStreamIDs: Set<String>
  /// A projected live row reserves its one initial entrance before a native
  /// host exists. This makes arrival, rather than virtualization, decide
  /// whether first-mount content should animate.
  private var reservedInitialAnimationStreamIDs: Set<String> = []
  private var hasEstablishedBaseline: Bool
  private var visibilityGeneration: Int?
  private var settlementTokens: [String: Int] = [:]
  private var settledRestorationIDs: Set<Int> = []
  private var nextSettlementToken = 0
  public private(set) var animationsEnabled = true

  public init() {
    presentedStreamIDs = []
    hasEstablishedBaseline = false
  }

  public init(settledStreamIDs: [String]) {
    presentedStreamIDs = Set(settledStreamIDs)
    hasEstablishedBaseline = true
  }

  /// Records the streams present at the navigation/mount boundary. The
  /// builder is deliberately lazy: SwiftUI may reconstruct its value on
  /// every streamed flush, but collecting a turn's entries should happen
  /// only once for this presentation object.
  public func establishBaseline(_ streamIDs: () -> [String]) {
    guard !hasEstablishedBaseline else { return }
    presentedStreamIDs.formUnion(streamIDs())
    hasEstablishedBaseline = true
  }

  /// Returns true only for a semantic stream first seen during this mounted
  /// presentation. A later native-view remount of the same stream baselines
  /// its current contents instead of replaying their entrance animation.
  public func claimInitialAnimation(for streamID: String) -> Bool {
    if reservedInitialAnimationStreamIDs.remove(streamID) != nil {
      presentedStreamIDs.insert(streamID)
      return true
    }
    return presentedStreamIDs.insert(streamID).inserted
  }

  /// Reserves one entrance for rows whose content arrived at the visible
  /// live edge (or while application playback was suspended). A reservation
  /// survives an offscreen first mount but is consumed exactly once.
  public func reserveInitialAnimations<S: Sequence>(for streamIDs: S)
  where S.Element == String {
    for streamID in streamIDs where !presentedStreamIDs.contains(streamID) {
      reservedInitialAnimationStreamIDs.insert(streamID)
    }
  }

  /// Makes newly projected offscreen rows opaque on their first native
  /// frame. Already claimed streams are deliberately untouched so ordinary
  /// append animation can continue if their host remains warm.
  public func settleUnpresentedStreams<S: Sequence>(_ streamIDs: S)
  where S.Element == String {
    let unpresented = streamIDs.filter {
      !presentedStreamIDs.contains($0)
        && !reservedInitialAnimationStreamIDs.contains($0)
    }
    settle(Array(unpresented))
  }

  /// Re-baselines every projected stream at a presentation boundary. Unlike
  /// ``settleUnpresentedStreams(_:)``, this also invalidates already-mounted
  /// streams so retained native rows seed their current document snapshot
  /// instead of revealing text that accumulated while the reader was away.
  public func settleProjectedStreams<S: Sequence>(_ streamIDs: S)
  where S.Element == String {
    settle(Array(streamIDs))
  }

  /// Applies one view-appearance boundary. Repeated body evaluations in the
  /// same generation must not settle text that arrived live afterward.
  public func updateVisibility(
    generation: Int,
    isVisible: Bool,
    settling streamIDs: () -> [String]
  ) {
    animationsEnabled = isVisible
    guard isVisible, visibilityGeneration != generation else { return }
    visibilityGeneration = generation
    settle(streamIDs())
  }

  /// Marks one asynchronous durable-history hydration as already presented.
  /// The restoration id makes this idempotent while allowing later live
  /// streams in the same turn to animate normally.
  public func settleRestoredStreams(
    _ streamIDs: () -> [String],
    restorationID: Int
  ) {
    guard settledRestorationIDs.insert(restorationID).inserted else { return }
    settle(streamIDs())
  }

  /// Changes whenever an already-mounted semantic stream must baseline its
  /// current contents again, such as after navigation or history hydration.
  public func settlementToken(for streamID: String) -> Int? {
    settlementTokens[streamID]
  }

  private func settle(_ streamIDs: [String]) {
    guard !streamIDs.isEmpty else { return }
    nextSettlementToken &+= 1
    for streamID in streamIDs {
      reservedInitialAnimationStreamIDs.remove(streamID)
      presentedStreamIDs.insert(streamID)
      settlementTokens[streamID] = nextSettlementToken
    }
  }
}
