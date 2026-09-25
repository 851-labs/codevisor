import AppKit
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

// MARK: - Send transition

extension VirtualizedTranscriptScrollView: TranscriptSendTransitionAdapter {
  var sendTransitionMountedHosts: [String: TranscriptMountedRowHost] { mountedHosts }

  var sendTransitionViewportHeight: CGFloat { contentView.bounds.height }

  func sendTransitionRowIndex(for key: String) -> Int? {
    virtualLayout.indexByKey[key]
  }

  /// Window coordinates are bottom-left based; the transitions work top-down.
  func sendTransitionScreenY(of host: TranscriptMountedRowHost) -> CGFloat {
    -host.convert(host.bounds, to: nil).maxY
  }

  func sendTransitionIsReady(_ host: TranscriptMountedRowHost) -> Bool {
    initialPositionApplied && contentView.bounds.height > 0 && host.isPresentationReady
  }

  /// The row as the transcript draws it, without the measured root's
  /// reporting hooks: the flight's copy must never publish readiness or
  /// heights for the real row.
  func sendTransitionRowContent(for key: String) -> AnyView? {
    guard let row = rowByKey[key], let rowContent else { return nil }
    return AnyView(
      rowContent(row)
        .environment(\.streamMarkdownTextLayoutWidth, effectiveRowWidth)
        .frame(width: effectiveRowWidth, alignment: .topLeading)
    )
  }

  /// Without a composer snapshot the row rises from just above the bottom
  /// chrome (the queue or the composer).
  func sendTransitionLiftOffset(for host: TranscriptMountedRowHost) -> CGFloat {
    let bottomSpacerHeight =
      rows.last { $0.id == .bottomSpacer }.flatMap { row -> CGFloat? in
        guard case let .bottomSpacer(height) = row.content else { return nil }
        return height
      } ?? 0
    // The spacer includes 24 pt of breathing room above the measured
    // bottom overlay; its inverse lands just above the composer.
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
  /// A host finished laying out. Flights start on the next frame, never
  /// inside the host's AppKit layout callback.
  func requestDisplayFrameOrLayout() {
    guard !isDetaching else { return }
    if presentationDisplayLink != nil {
      requestDisplayFrame()
    } else {
      needsLayout = true
    }
  }

  /// Retires rows that moved out of the window once the send's springs
  /// have carried them there; until then they stay mounted.
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
