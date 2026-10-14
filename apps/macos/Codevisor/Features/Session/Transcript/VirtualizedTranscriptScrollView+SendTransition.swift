import AppKit
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

extension VirtualizedTranscriptScrollView: TranscriptSendTransitionAdapter {
  var sendTransitionMountedHosts: [String: TranscriptMountedRowHost] { mountedHosts }

  var sendTransitionViewportHeight: CGFloat { contentView.bounds.height }

  func sendTransitionRowIndex(for key: String) -> Int? {
    virtualLayout.indexByKey[key]
  }

  func sendTransitionScreenY(of host: TranscriptMountedRowHost) -> CGFloat {
    -host.convert(host.bounds, to: nil).maxY
  }

  func sendTransitionIsReady(_ host: TranscriptMountedRowHost) -> Bool {
    initialPositionApplied && contentView.bounds.height > 0 && host.isPresentationReady
  }

  func sendTransitionRowContent(for key: String) -> AnyView? {
    guard let row = rowByKey[key], let rowContent else { return nil }
    return AnyView(
      rowContent(row)
        .environment(\.streamMarkdownTextLayoutWidth, effectiveRowWidth)
        .frame(width: effectiveRowWidth, alignment: .topLeading)
    )
  }

  func sendTransitionLiftOffset(for host: TranscriptMountedRowHost) -> CGFloat {
    let bottomSpacerHeight =
      rows.last { $0.id == .bottomSpacer }.flatMap { row -> CGFloat? in
        guard case let .bottomSpacer(height) = row.content else { return nil }
        return height
      } ?? 0
    let sourceY = contentView.bounds.maxY - bottomSpacerHeight + 48
    return sourceY - host.frame.minY
  }

  func sendTransitionWillPresent() {
    if initialPresentationGate.openForSendPresentation(
      isHydrating: isLoadingInitialHistory || isPreparingInitialProjection
    ) {
      presentInitialTranscript()
    }
  }
}

extension VirtualizedTranscriptScrollView {
  func requestDisplayFrameOrLayout() {
    guard !isDetaching else { return }
    if presentationDisplayLink != nil {
      requestDisplayFrame()
    } else {
      needsLayout = true
    }
  }

  func requestMountedRowsUpdateAfterSendTransition() {
    guard !isSendTransitionCleanupScheduled else { return }
    isSendTransitionCleanupScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      isSendTransitionCleanupScheduled = false
      guard !isDetaching else { return }
      requestMountedRowsUpdate()
    }
  }
}
