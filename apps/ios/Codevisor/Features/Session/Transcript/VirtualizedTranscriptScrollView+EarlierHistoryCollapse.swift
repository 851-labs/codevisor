import CodevisorUI
import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
  static let earlierHistoryCollapsedRecentOffset: CGFloat = 120

  func updateCollapsibleEarlierHistory() {
    guard !isDetaching else { return }
    let visibleTop = contentOffset.y + appliedTopContentInset
    let section =
      initialPresentationGate.isReady
      ? TranscriptEarlierHistoryCollapseTarget.section(
        in: virtualLayout,
        rowByKey: rowByKey,
        viewportTop: visibleTop - transcriptRowsOrigin,
        viewportBottom: contentOffset.y + bounds.height - transcriptRowsOrigin
      )
      : nil
    guard section != collapsibleEarlierHistorySection else { return }
    collapsibleEarlierHistorySection = section
    onEarlierHistoryCollapseChange?(
      section.map { section in
        TranscriptEarlierHistoryCollapse(section: section) { [weak self] change in
          self?.performEarlierHistoryCollapse(of: section, change: change) ?? change()
        }
      }
    )
  }

  private func performEarlierHistoryCollapse(
    of section: TranscriptWorkedSectionIdentity,
    change: @escaping () -> Void
  ) {
    if let index = TranscriptEarlierHistoryCollapseTarget.recentRowIndex(
      of: section, in: virtualLayout, rowByKey: rowByKey
    ) {
      let visibleTop = contentOffset.y + appliedTopContentInset
      let rowTop = transcriptRowsOrigin + virtualLayout.frame(at: index).minY
      let currentOffset = rowTop - contentOffset.y
      let offset =
        (visibleTop...(contentOffset.y + bounds.height)).contains(rowTop)
        ? currentOffset
        : appliedTopContentInset + Self.earlierHistoryCollapsedRecentOffset
      beginDisclosureViewportAnchor(row: (virtualLayout.keys[index], offset))
    }
    change()
  }
}
