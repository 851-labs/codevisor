import Foundation

@MainActor
public final class StreamingTextAnimationPresentation {
  private var presentedStreamIDs: Set<String>
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

  public func establishBaseline(_ streamIDs: () -> [String]) {
    guard !hasEstablishedBaseline else { return }
    presentedStreamIDs.formUnion(streamIDs())
    hasEstablishedBaseline = true
  }

  public func claimInitialAnimation(for streamID: String) -> Bool {
    if reservedInitialAnimationStreamIDs.remove(streamID) != nil {
      presentedStreamIDs.insert(streamID)
      return true
    }
    return presentedStreamIDs.insert(streamID).inserted
  }

  public func reserveInitialAnimations<S: Sequence>(for streamIDs: S)
  where S.Element == String {
    for streamID in streamIDs where !presentedStreamIDs.contains(streamID) {
      reservedInitialAnimationStreamIDs.insert(streamID)
    }
  }

  public func settleUnpresentedStreams<S: Sequence>(_ streamIDs: S)
  where S.Element == String {
    let unpresented = streamIDs.filter {
      !presentedStreamIDs.contains($0)
        && !reservedInitialAnimationStreamIDs.contains($0)
    }
    settle(Array(unpresented))
  }

  public func settleProjectedStreams<S: Sequence>(_ streamIDs: S)
  where S.Element == String {
    settle(Array(streamIDs))
  }

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

  public func settleRestoredStreams(
    _ streamIDs: () -> [String],
    restorationID: Int
  ) {
    guard settledRestorationIDs.insert(restorationID).inserted else { return }
    settle(streamIDs())
  }

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
