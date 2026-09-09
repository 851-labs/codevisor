import AppKit
import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import Testing
import TranscriptKit
@testable import TranscriptSurface

@Suite("Initial transcript mounting", .serialized)
@MainActor
struct TranscriptInitialMountBudgetTests {
  private func surface() -> VirtualizedTranscriptScrollView {
    _ = NSApplication.shared
    let view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.layoutSubtreeIfNeeded()
    view.isPreparingInitialProjection = false
    view.initialPositionConfigured = true
    view.initialPositionApplied = true
    view.mountWorkTime = { 0 }
    let rows = (0..<20).map { index in
      TranscriptVirtualRow(id: .message(UUID()), content: .error("Row \(index)"), estimatedHeight: 24)
    }
    view.rowContent = { AnyView(Color.clear.frame(height: $0.estimatedHeight)) }
    _ = view.rowSet.replaceRows(rows)
    for row in rows { view.measurements.setExact(row.estimatedHeight, for: row.layoutKey) }
    // The test owns frame delivery; this display link is never registered
    // with a run loop. Mount counts cannot depend on scheduler timing.
    view.presentationDisplayLink = view.displayLink(
      target: view, selector: #selector(view.presentationDisplayLinkDidFire(_:)))
    return view
  }

  @Test("Cold viewport preparation yields when its mount allowance is exhausted")
  func coldWindowYields() {
    let view = surface()
    defer { view.prepareForDismantle() }
    view.remainingMountsThisFrame = 2

    view.rebuildDocumentGeometry()

    #expect(view.mountedHosts.count == 2)
    #expect(!view.isInitialPresentationReady)
    #expect(view.mountedRowsUpdateRequested)
    // Extra layout/readiness requests in the same frame cannot bypass it.
    view.updateMountedRows()
    view.updateInitialPresentationReadiness()
    #expect(view.mountedHosts.count == 2)
    // The next display frame renews the allowance and resumes preparation.
    if let link = view.presentationDisplayLink {
      view.presentationDisplayLinkDidFire(link)
    }
    #expect(view.mountedHosts.count > 2)
    #expect(view.mountedHosts.count <= 2 + view.maximumMountsPerFrame)
  }

  @Test("Cold mounting yields when the work clock reaches the frame budget")
  func coldWindowHonorsTimeBudget() {
    let view = surface()
    defer { view.prepareForDismantle() }
    var time: CFTimeInterval = 0
    view.mountWorkTime = { time }
    view.rowContent = { row in
      time += view.mountWorkBudget
      return AnyView(Color.clear.frame(height: row.estimatedHeight))
    }
    view.remainingMountsThisFrame = 20

    view.rebuildDocumentGeometry()

    #expect(view.mountedHosts.count == 1)
    #expect(view.mountedRowsUpdateRequested)
    #expect(!view.isInitialPresentationReady)
    view.updateMountedRows()
    #expect(view.mountedHosts.count == 1)
  }

  @Test("A visible transcript still mounts its complete viewport immediately")
  func visibleWindowKeepsCoverage() {
    let view = surface()
    defer { view.prepareForDismantle() }
    // Initial presentation has already completed; the next layout models
    // scrolling into loaded rows with no speculative mount budget left.
    _ = view.initialPresentationGate.resolve(
      isHydrating: false, requiredKeys: [], resolvedKeys: [], hasPendingMeasurements: false)
    view.remainingMountsThisFrame = 0

    view.rebuildDocumentGeometry()

    let visible = view.virtualLayout.visibleRange(
      distanceFromBottom: view.currentDistanceFromBottom(), viewportHeight: view.contentView.bounds.height,
      overscanCount: 0)
    #expect(visible.count > 2)
    #expect(visible.allSatisfy { view.mountedHosts[view.virtualLayout.keys[$0]] != nil })
  }
}
