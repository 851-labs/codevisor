import AppKit
import CodevisorUI
import QuartzCore
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func mountViewportRows(
    at indices: [Int],
    budgetsInitialWindow: Bool,
    workStartedAt: CFTimeInterval
  ) {
    for index in indices {
      if budgetsInitialWindow, virtualLayout.keys.indices.contains(index) {
        let host = mountedHosts[virtualLayout.keys[index]]
        if host?.isPresentationReady != true {
          guard remainingMountsThisFrame > 0,
            mountWorkTime() - workStartedAt < mountWorkBudget
          else { break }
          remainingMountsThisFrame -= 1
        }
      }
      mountRow(at: index, requiresImmediatePresentation: true)
    }
    assert(
      budgetsInitialWindow
        || indices.allSatisfy { index in
          guard virtualLayout.keys.indices.contains(index) else { return false }
          return mountedHosts[virtualLayout.keys[index]] != nil
        },
      "Loaded transcript viewport must be fully mounted"
    )
  }
}
