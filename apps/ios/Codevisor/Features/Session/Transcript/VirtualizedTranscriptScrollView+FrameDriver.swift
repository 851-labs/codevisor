import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - FrameDriver

extension VirtualizedTranscriptScrollView {
    func prepareForDismantle() {
        if presentationRole == .foreground {
            // Capture the live, post-measurement coordinate before UIKit
            // starts changing bounds and safe-area geometry during teardown.
            emitViewportSnapshot()
        } else {
            republishLastStableScrollState()
        }
        isDetaching = true
        uninstallPresentationDisplayLink()
        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        pendingMeasurements.removeAll(keepingCapacity: false)
        bottomJumpGate.cancel()
        deferredRowsDuringScroll = nil
        deferredActiveRowsRange = nil
        deferredProjectionRevision = nil
        olderHistoryPresentationTarget = nil
        disclosureAnchorReleaseTask?.cancel()
        interruptSendPresentation()
        for host in mountedHosts.values {
            host.removeFromSuperview()
            host.detachFromParent()
        }
        mountedHosts.removeAll(keepingCapacity: false)
        virtualWindowHandoff.reset()
        discardParkedHosts()
    }

    func installPresentationDisplayLink() {
        guard presentationDisplayLink == nil, let window else { return }
        guard
            let displayLink = window.screen.displayLink(
                withTarget: self,
                selector: #selector(presentationDisplayLinkDidFire(_:))
            )
        else { return }
        let rate = Float(max(1, window.screen.maximumFramesPerSecond))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate,
            maximum: rate,
            preferred: rate
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        presentationDisplayLink = displayLink
        streamingTextFrameClock.setFrameRequester { [weak self] in
            self?.requestDisplayFrame()
        }
        updatePresentationFrameDriverRegistration()
        if !pendingMeasurements.isEmpty {
            requestDisplayFrame()
        }
    }

    func uninstallPresentationDisplayLink() {
        streamingTextFrameClock.setFrameRequester(nil)
        unregisterPresentationFrameDriver()
        presentationDisplayLink?.invalidate()
        presentationDisplayLink = nil
        displayFrameRequested = false
        modelPresentationFrameRequested = false
        mountedRowsUpdateRequested = false
    }

    func updatePresentationFrameDriverRegistration() {
        guard presentationRole == .foreground,
            presentationFrameDriverToken == nil,
            let presentationDisplayLink,
            let sessionController,
            let window
        else {
            if presentationRole != .foreground {
                unregisterPresentationFrameDriver()
            }
            return
        }
        presentationFrameDriverToken = sessionController.registerTranscriptFrameDriver(
            maximumFramesPerSecond: max(1, window.screen.maximumFramesPerSecond)
        ) { [weak self] in
            self?.requestModelPresentationFrame()
        }
        // Keep the local link alive only through explicit frame requests.
        presentationDisplayLink.isPaused = !displayFrameRequested
    }

    func unregisterPresentationFrameDriver() {
        if let presentationFrameDriverToken {
            sessionController?.unregisterTranscriptFrameDriver(presentationFrameDriverToken)
            self.presentationFrameDriverToken = nil
        }
    }

    func requestDisplayFrame() {
        guard let presentationDisplayLink else { return }
        displayFrameRequested = true
        presentationDisplayLink.isPaused = false
    }

    func requestModelPresentationFrame() {
        modelPresentationFrameRequested = true
        requestDisplayFrame()
    }

    func requestMountedRowsUpdate() {
        guard presentationDisplayLink != nil else {
            updateMountedRows()
            return
        }
        mountedRowsUpdateRequested = true
        requestDisplayFrame()
    }

    @objc func presentationDisplayLinkDidFire(_ displayLink: CADisplayLink) {
        let shouldPresentModel = modelPresentationFrameRequested
        let shouldUpdateMountedRows = mountedRowsUpdateRequested
        remainingMountsThisFrame = maximumMountsPerFrame
        displayFrameRequested = false
        modelPresentationFrameRequested = false
        mountedRowsUpdateRequested = false
        if shouldPresentModel, let presentationFrameDriverToken {
            sessionController?.transcriptPresentationFrameDidFire(presentationFrameDriverToken)
        }
        if shouldUpdateMountedRows {
            updateMountedRows()
        }
        if !pendingMeasurements.isEmpty,
            measurementCommitGate.allowsGeometryCommit
        {
            commitPendingMeasurements()
        }
        streamingTextFrameClock.tick(at: displayLink.timestamp)
        displayLink.isPaused = !displayFrameRequested
    }
}
