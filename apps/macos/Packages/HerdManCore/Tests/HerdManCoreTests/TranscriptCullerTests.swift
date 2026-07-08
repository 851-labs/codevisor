import CoreGraphics
import Foundation
import Testing
@testable import HerdManCore

@MainActor
@Suite("TranscriptCuller")
struct TranscriptCullerTests {
    // Ten rows of 100pt each, 20pt spacing, 28pt top padding:
    // row i top = 28 + i*120, bottom = 128 + i*120.
    private func fixedOrder(_ count: Int, height: CGFloat = 100) -> (ids: [UUID], heights: [UUID: CGFloat]) {
        let ids = (0..<count).map { _ in UUID() }
        var heights: [UUID: CGFloat] = [:]
        for id in ids { heights[id] = height }
        return (ids, heights)
    }

    /// Drives a full-detail recompute (no margin, no throttle) and returns the
    /// set of ids left mounted.
    private func mountedAfterRecompute(
        _ culler: TranscriptCuller, ids: [UUID], heights: [UUID: CGFloat],
        contentOffset: CGFloat, viewportHeight: CGFloat, margin: CGFloat = 0
    ) -> Set<UUID> {
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        culler.recompute(
            contentOffset: contentOffset, viewportHeight: viewportHeight,
            mountMargin: margin, keepMargin: margin, minStep: 0
        )
        return Set(ids.filter { culler.mountState(for: $0).isMounted })
    }

    @Test("Only rows intersecting viewport ± margin mount")
    func windowCulls() {
        let (ids, heights) = fixedOrder(50)
        // Viewport 300pt tall at offset 0, margin 0: rows whose extent
        // intersects [0, 300]. Row tops: 28,148,268,388… so rows 0,1,2 mount.
        let m = mountedAfterRecompute(TranscriptCuller(), ids: ids, heights: heights,
                                      contentOffset: 0, viewportHeight: 300)
        #expect(m.contains(ids[0]) && m.contains(ids[1]) && m.contains(ids[2]))
        #expect(!m.contains(ids[3]))
        #expect(!m.contains(ids[49]))
    }

    @Test("Margin extends the mounted band symmetrically")
    func marginBand() {
        let (ids, heights) = fixedOrder(50)
        // Offset 1200, viewport 300, margin 300 → band [900, 1800]; rows ~7..14.
        let m = mountedAfterRecompute(TranscriptCuller(), ids: ids, heights: heights,
                                      contentOffset: 1200, viewportHeight: 300, margin: 300)
        #expect(!m.contains(ids[5]))
        #expect(m.contains(ids[9]) && m.contains(ids[10]) && m.contains(ids[12]))
        #expect(!m.contains(ids[20]))
    }

    @Test("A single unmeasured row far below still lets measured rows cull")
    func mixedMeasuredUnmeasured() {
        var (ids, heights) = fixedOrder(50)
        heights[ids[40]] = nil // row 40 newly appended, not yet measured
        let m = mountedAfterRecompute(TranscriptCuller(), ids: ids, heights: heights,
                                      contentOffset: 0, viewportHeight: 300)
        #expect(m.contains(ids[40])) // unmeasured → forced mount
        #expect(!m.contains(ids[25])) // measured & far → culled
    }

    @Test("Culler flips only per-row observable flags; instances are stable")
    func mountStateStability() {
        let culler = TranscriptCuller()
        let (ids, heights) = fixedOrder(10)
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        let stateFor5 = culler.mountState(for: ids[5])
        culler.recompute(contentOffset: 0, viewportHeight: 200, mountMargin: 0, keepMargin: 0, minStep: 0)
        // Same instance returned across recomputes (identity stable for SwiftUI).
        #expect(culler.mountState(for: ids[5]) === stateFor5)
        #expect(stateFor5.isMounted == false) // row 5 (top 628) far from [0,200]
        #expect(culler.mountState(for: ids[0]).isMounted == true)
    }

    @Test("Hysteresis keeps a mounted row until it passes the wider keep band")
    func hysteresisBand() {
        let culler = TranscriptCuller()
        let (ids, heights) = fixedOrder(50)
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        let row20 = ids[20] // top 2428, bottom 2528
        // Mount it: mount band [2200, 2600] contains the row.
        culler.recompute(contentOffset: 2300, viewportHeight: 200, mountMargin: 100, keepMargin: 500, minStep: 0)
        #expect(culler.mountState(for: row20).isMounted)
        // Scroll so it leaves the mount band [1850,2250] but stays in the keep
        // band [1450,2650] → hysteresis keeps it mounted.
        culler.recompute(contentOffset: 1950, viewportHeight: 200, mountMargin: 100, keepMargin: 500, minStep: 0)
        #expect(culler.mountState(for: row20).isMounted)
        // Scroll past the keep band [1200,2400] (row top 2428 > 2400) → unmount.
        culler.recompute(contentOffset: 1700, viewportHeight: 200, mountMargin: 100, keepMargin: 500, minStep: 0)
        #expect(!culler.mountState(for: row20).isMounted)
    }

    @Test("Throttle skips recompute for sub-minStep moves")
    func throttle() {
        let culler = TranscriptCuller()
        let (ids, heights) = fixedOrder(50)
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        // First compute is forced (offset unset); row 5 (top 628) is out.
        culler.recompute(contentOffset: 0, viewportHeight: 200, mountMargin: 0, keepMargin: 0, minStep: 40)
        #expect(!culler.mountState(for: ids[5]).isMounted)
        // Move only 30pt (< 40) with a margin that WOULD mount row 5 — throttled.
        culler.recompute(contentOffset: 30, viewportHeight: 200, mountMargin: 500, keepMargin: 500, minStep: 40)
        #expect(!culler.mountState(for: ids[5]).isMounted)
        // Move 60pt (≥ 40) → recompute runs → row 5 mounts.
        culler.recompute(contentOffset: 60, viewportHeight: 200, mountMargin: 500, keepMargin: 500, minStep: 40)
        #expect(culler.mountState(for: ids[5]).isMounted)
    }

    @Test("setOrder forces the next throttled recompute")
    func orderForcesRecompute() {
        let culler = TranscriptCuller()
        let (ids, heights) = fixedOrder(10)
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        culler.recompute(contentOffset: 0, viewportHeight: 200, mountMargin: 0, keepMargin: 0, minStep: 40)
        // A tiny move would normally be throttled, but re-setting the order
        // forces the recompute to run.
        culler.setOrder(ids)
        culler.recompute(contentOffset: 5, viewportHeight: 200, mountMargin: 5000, keepMargin: 5000, minStep: 40)
        #expect(ids.allSatisfy { culler.mountState(for: $0).isMounted })
    }

    @Test("mountAll re-mounts every row (idle mode)")
    func mountAllMountsEverything() {
        let culler = TranscriptCuller()
        let (ids, heights) = fixedOrder(40)
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        // Cull first so some rows are spacers.
        culler.recompute(contentOffset: 5000, viewportHeight: 300, mountMargin: 0, keepMargin: 0, minStep: 0)
        #expect(!ids.allSatisfy { culler.mountState(for: $0).isMounted })
        // Turn finished → mount all for reading.
        culler.mountAll()
        #expect(ids.allSatisfy { culler.mountState(for: $0).isMounted })
    }

    @Test("Disabled culling makes recompute a no-op")
    func disabledRecomputeNoOp() {
        let culler = TranscriptCuller()
        let (ids, heights) = fixedOrder(10)
        culler.setOrder(ids)
        for (id, h) in heights { culler.setHeight(h, for: id) }
        culler.mountAll()
        culler.cullingEnabled = false
        // A recompute that would otherwise cull far rows does nothing.
        culler.recompute(contentOffset: 5000, viewportHeight: 100, mountMargin: 0, keepMargin: 0, minStep: 0)
        #expect(ids.allSatisfy { culler.mountState(for: $0).isMounted })
    }

    @Test("Width change invalidates cached heights")
    func widthInvalidation() {
        let culler = TranscriptCuller()
        let (ids, _) = fixedOrder(5)
        culler.setOrder(ids)
        culler.noteWidth(880)
        for id in ids { culler.setHeight(100, for: id) }
        #expect(culler.height(for: ids[0]) == 100)
        culler.noteWidth(600) // narrower column → rewrap → heights stale
        #expect(culler.height(for: ids[0]) == nil)
    }

    @Test("setHeight reports the delta from the previous measurement")
    func heightDelta() {
        let culler = TranscriptCuller()
        let id = UUID()
        #expect(culler.setHeight(100, for: id) == 0) // first measurement
        #expect(culler.setHeight(140, for: id) == 40) // grew 40
        #expect(culler.setHeight(120, for: id) == -20) // shrank 20
    }

    @Test("setOrder drops state for rows no longer present")
    func orderPruning() {
        let culler = TranscriptCuller()
        let (ids, _) = fixedOrder(5)
        culler.setOrder(ids)
        for id in ids { culler.setHeight(50, for: id) }
        culler.setOrder(Array(ids.prefix(3)))
        #expect(culler.height(for: ids[4]) == nil)
        #expect(culler.height(for: ids[0]) == 50)
    }
}
