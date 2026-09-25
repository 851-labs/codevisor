import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - Send transition

extension VirtualizedTranscriptScrollView {
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

extension VirtualizedTranscriptScrollView: TranscriptSendTransitionAdapter {
  var sendTransitionMountedHosts: [String: TranscriptRowHost] { mountedHosts }

  var sendTransitionViewportHeight: CGFloat { viewportHeight }

  func sendTransitionRowIndex(for key: String) -> Int? {
    virtualLayout.indexByKey[key]
  }

  func sendTransitionScreenY(of host: TranscriptRowHost) -> CGFloat {
    host.convert(host.bounds, to: nil).minY
  }

  func sendTransitionIsReady(_ host: TranscriptRowHost) -> Bool {
    initialPositionApplied && host.isPresentationReady
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

  /// Without a composer snapshot the row rises from the editor (or, before
  /// the composer has reported its frame, from just below the transcript's
  /// visible bottom).
  func sendTransitionLiftOffset(for host: TranscriptRowHost) -> CGFloat {
    let sourceY: CGFloat
    if let frame = sendAnimationSourceFrame {
      sourceY = canvasView.convert(CGPoint(x: frame.midX, y: frame.midY), from: nil).y
    } else {
      let bottomSpacerHeight =
        rows.last { $0.id == .bottomSpacer }.flatMap { row in
          if case let .bottomSpacer(height) = row.content { height } else { nil }
        } ?? 0
      sourceY = contentOffset.y + bounds.height - bottomSpacerHeight + 48
    }
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
