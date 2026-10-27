import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  static let earlierHistoryCollapsedRecentOffset: CGFloat = 120

  func updateCollapsibleEarlierHistory() {
    let section =
      isInitialPresentationReady
      ? TranscriptEarlierHistoryCollapseTarget.section(
        in: virtualLayout,
        rowByKey: rowByKey,
        viewportTop: unobstructedViewport.minY - transcriptRowsOrigin,
        viewportBottom: contentView.bounds.maxY - transcriptRowsOrigin
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
      let currentOffset = rowFrame(at: index).minY - contentView.bounds.minY
      let offset =
        (0...contentView.bounds.height).contains(currentOffset)
        ? currentOffset
        : Self.earlierHistoryCollapsedRecentOffset
      beginDisclosureViewportAnchor(row: (virtualLayout.keys[index], offset))
    }
    change()
  }
}
