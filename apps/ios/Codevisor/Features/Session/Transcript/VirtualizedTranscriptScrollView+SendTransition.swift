import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
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

  var sendTransitionLanding: TranscriptSendLanding? {
    guard window != nil else { return nil }
    let viewportWidth = max(1, bounds.width)
    let rowWidth = min(Self.maxRowWidth, max(1, viewportWidth - Self.horizontalPadding * 2))
    let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
    let corner = convert(
      CGPoint(x: rowX + rowWidth, y: contentOffset.y + appliedTopContentInset + Self.runwayTopClearance),
      to: nil)
    return TranscriptSendLanding(trailing: corner.x, top: corner.y, maxBubbleWidth: rowWidth - 40)
  }

  var sendTransitionPushDistance: CGFloat? {
    guard let landing = sendTransitionLanding,
      let spacerIndex = virtualLayout.indexByKey[TranscriptVirtualRow.ID.bottomSpacer.layoutKey]
    else { return nil }
    let turnTop = transcriptRowsOrigin + virtualLayout.frame(at: spacerIndex).minY
    return canvasView.convert(CGPoint(x: 0, y: turnTop), to: nil).y - landing.top
  }

  func sendTransitionPinRowsToViewport() {
    for key in layer.animationKeys() ?? [] where key.hasPrefix("bounds.origin") {
      guard let animation = layer.animation(forKey: key) as? CABasicAnimation, animation.isAdditive,
        let from = (animation.fromValue as? NSValue)?.cgPointValue,
        let to = (animation.toValue as? NSValue)?.cgPointValue
      else { continue }
      let identity = "\(key)@\(from.y)"
      guard pinnedViewportAnimations.insert(identity).inserted,
        let pin = animation.copy() as? CABasicAnimation
      else { continue }
      pin.keyPath = "transform.translation.y"
      pin.fromValue = from.y
      pin.toValue = to.y
      pin.delegate = nil
      for host in mountedHosts.values {
        host.layer.add(pin, forKey: "codevisor.send-viewport.\(identity)")
      }
    }
  }

  func sendTransitionRowIndex(for key: String) -> Int? {
    virtualLayout.indexByKey[key]
  }

  func sendTransitionScreenY(of host: TranscriptRowHost) -> CGFloat {
    host.convert(host.bounds, to: nil).minY
  }

  func sendTransitionIsReady(_ host: TranscriptRowHost) -> Bool {
    initialPositionApplied && host.isPresentationReady
  }

  func sendTransitionCommitHeight(_ rawHeight: CGFloat, for key: String) {
    let height = max(1, rawHeight.rounded(.up))
    pendingMeasurements.removeValue(forKey: key)
    guard rowByKey[key] != nil, measurements.needsCommit(height, for: key),
      storeMeasuredHeight(height, for: key)
    else { return }
    rebuildDocumentGeometry(changedHeights: [key: height])
  }

  func sendTransitionRowContent(for key: String) -> AnyView? {
    guard let row = rowByKey[key], let rowContent else { return nil }
    return AnyView(
      rowContent(row)
        .environment(\.streamMarkdownTextLayoutWidth, effectiveRowWidth)
        .frame(width: effectiveRowWidth, alignment: .topLeading)
    )
  }

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
