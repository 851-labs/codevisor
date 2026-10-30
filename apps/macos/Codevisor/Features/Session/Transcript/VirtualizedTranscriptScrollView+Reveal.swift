import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  private static let revealedRowViewportFraction: CGFloat = 0.3
  private static let revealSettlePasses = 3

  func reveal(_ location: TranscriptWorkedItemLocation) {
    pendingReveal = location
    revealPendingRowIfPossible()
  }

  func revealPendingRowIfPossible() {
    guard let location = pendingReveal, initialPresentationGate.isReady,
      let key = revealedRowKey(for: location)
    else { return }

    pendingReveal = nil
    for _ in 0..<Self.revealSettlePasses {
      guard let index = virtualLayout.indexByKey[key] else { return }
      scrollAsUserInput(toTop: revealedViewportTop(forRowAt: index))
      transcriptDocumentView.layoutSubtreeIfNeeded()
    }
  }

  private func revealedRowKey(for location: TranscriptWorkedItemLocation) -> String? {
    rows.first { $0.id.workedItemReference == location.reference }?.layoutKey
  }

  private func revealedViewportTop(forRowAt index: Int) -> CGFloat {
    let region = unobstructedViewport
    let obstructedTop = region.minY - contentView.bounds.minY
    return rowFrame(at: index).minY - obstructedTop - region.height * Self.revealedRowViewportFraction
  }
}

extension TranscriptVirtualRow.ID {
  fileprivate var workedItemReference: TranscriptWorkedItemReference? {
    switch self {
    case let .assistantWorkedItem(messageID, section, itemID), let .activeWorkedItem(messageID, section, itemID):
      TranscriptWorkedItemReference(messageID: messageID, section: section, itemID: itemID)
    default:
      nil
    }
  }
}
