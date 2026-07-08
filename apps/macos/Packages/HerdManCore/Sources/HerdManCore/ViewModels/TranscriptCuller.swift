import CoreGraphics
import Foundation
import Observation

/// Occlusion culling for the eager transcript.
///
/// The transcript stays a plain (non-lazy) VStack of one wrapper per settled
/// row — so the scroll view still gets an exact content size and one truthful,
/// continuous scrollbar (the reason `LazyVStack`, which only *estimates*
/// off-screen heights, was rejected). But each wrapper renders its real content
/// only when the row is within a margin of the viewport; otherwise it renders a
/// fixed-height spacer using the row's last MEASURED height. Per-frame layout
/// and render work therefore becomes `O(visible)` instead of `O(conversation)`.
///
/// Ownership: one instance per session, held on `SessionController`
/// (`@ObservationIgnored`), so it survives the session screen remounting — a
/// reopened long chat culls from the first frame instead of re-mounting
/// everything.
///
/// Not `@Observable`: heights/order/width are plain storage read WITHOUT
/// registering an Observation dependency (the spacer reads `height(for:)` in
/// its body, but on a non-observed class, so it tracks nothing). The only
/// observed state is each row's `RowMountState`, so flipping one row's mount
/// flag invalidates exactly that one wrapper — never the whole transcript.
@MainActor
public final class TranscriptCuller {
    /// Per-row mount flag. `@Observable` so a wrapper that reads `isMounted`
    /// re-renders (content ↔ spacer) when only its own flag flips.
    @MainActor
    @Observable
    public final class RowMountState {
        public var isMounted: Bool
        init(_ isMounted: Bool) { self.isMounted = isMounted }
    }

    /// Master switch (VoiceOver / debug A-B toggle). When false every row
    /// mounts — identical to the pre-culling transcript.
    public var cullingEnabled: Bool = true

    // Geometry of the transcript VStack, used to turn row heights into content
    // offsets. These defaults mirror SessionView's `.padding(.top, 28)` and
    // `VStack(spacing: 20)`; keep them in sync if that layout changes.
    public var topPadding: CGFloat = 28
    public var rowSpacing: CGFloat = 20
    /// Height reserved for the pre-chat setup section above the first row.
    /// Left at 0: it's non-empty only for a brand-new session mid-setup, which
    /// has ~0 settled rows (nothing to cull or restore), so the small offset
    /// error is immaterial.
    public var setupHeight: CGFloat = 0

    private var order: [UUID] = []
    private var heights: [UUID: CGFloat] = [:]
    private var states: [UUID: RowMountState] = [:]
    private var measuredWidth: CGFloat?
    /// The offset the window was last computed at, for throttling. `.nan`
    /// forces the next recompute (set on order/width/enabled changes).
    private var lastComputeOffset: CGFloat = .nan
    /// The viewport height the window was last computed at — a resize at a
    /// fixed offset (pane toggle) must force a recompute even when throttled.
    private var lastComputeViewport: CGFloat = 0

    public init() {}

    // MARK: - Row state

    /// The mount flag for a row, created (defaulting to mounted) on first use.
    /// Creating one mutates a plain dict — not observed — so calling this from
    /// a view `body` is a safe idempotent cache fill.
    public func mountState(for id: UUID) -> RowMountState {
        if let existing = states[id] { return existing }
        let created = RowMountState(true)
        states[id] = created
        return created
    }

    public func height(for id: UUID) -> CGFloat? { heights[id] }

    /// Records a measured content height. Returns the delta from the previous
    /// measurement (0 if unchanged / first measurement), for scroll
    /// compensation of above-viewport corrections.
    @discardableResult
    public func setHeight(_ height: CGFloat, for id: UUID) -> CGFloat {
        let previous = heights[id]
        heights[id] = height
        return height - (previous ?? height)
    }

    /// Updates the column width the heights were measured at. A real change
    /// invalidates every cached height (wrapping changed), so every row
    /// remounts and remeasures once, then culling re-engages.
    public func noteWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        if let measuredWidth, abs(measuredWidth - width) > 0.5 {
            heights.removeAll(keepingCapacity: true)
            lastComputeOffset = .nan // force a recompute at the new width
        }
        measuredWidth = width
    }

    /// The current settled-row order. New rows default to mounted (unmeasured);
    /// rows that vanished (session reset) drop their state/height.
    public func setOrder(_ ids: [UUID]) {
        order = ids
        let live = Set(ids)
        states = states.filter { live.contains($0.key) }
        heights = heights.filter { live.contains($0.key) }
        lastComputeOffset = .nan // order changed → force a recompute
    }

    /// The top offset (content-space Y) of a row, from the prefix sum of
    /// heights above it. Backs scroll capture/restore arithmetically — no
    /// per-row geometry callbacks, so a fully-mounted transcript still scrolls
    /// at O(1) per frame.
    public func rowTop(_ id: UUID) -> CGFloat? {
        let estimate = averageHeight()
        var y = topPadding + setupHeight
        for rowID in order {
            if rowID == id { return y }
            y += (heights[rowID] ?? estimate) + rowSpacing
        }
        return nil
    }

    /// The topmost row intersecting the viewport top, and its top position
    /// relative to that viewport top (≤ 0 when the row starts above the fold).
    /// The scroll-restore anchor: immune to content above changing between
    /// mounts (turns collapsing, new messages), because it's resolved against
    /// the row identity, not a raw offset.
    public func topVisibleRow(contentOffset: CGFloat) -> (id: UUID?, delta: CGFloat) {
        let estimate = averageHeight()
        var y = topPadding + setupHeight
        for id in order {
            let bottom = y + (heights[id] ?? estimate)
            if bottom > contentOffset { return (id, y - contentOffset) }
            y = bottom + rowSpacing
        }
        return (order.last, 0)
    }

    // MARK: - Window

    /// Recomputes which rows should be mounted for a given viewport, flipping
    /// only the flags that change. Call inside a no-animation transaction so
    /// content↔spacer swaps never animate.
    ///
    /// Two things keep scrolling smooth:
    /// - **Hysteresis**: a row mounts when it enters `mountMargin` but isn't
    ///   unmounted until it passes the wider `keepMargin`. So scrolling back and
    ///   forth within a region doesn't thrash a row on/off (each flip is render
    ///   work — a potential dropped frame), which is the main cause of scroll
    ///   jitter in a culled list.
    /// - **Throttle**: sub-`minStep` offset nudges are ignored, so the flip
    ///   set is recomputed a handful of times per viewport of travel rather
    ///   than on every sub-pixel geometry tick (which also broke a re-entrancy
    ///   wobble where a flip's relayout fired another geometry callback).
    ///
    /// `minStep == 0` forces the compute (used when order/width just changed).
    public func recompute(
        contentOffset: CGFloat, viewportHeight: CGFloat,
        mountMargin: CGFloat, keepMargin: CGFloat, minStep: CGFloat
    ) {
        // When culling is off (idle — no turn generating), everything is
        // mounted via `mountAll()` at the transition; per-tick recompute is a
        // no-op so scrolling never mounts anything.
        guard cullingEnabled else { return }
        if !lastComputeOffset.isNaN, minStep > 0,
           abs(contentOffset - lastComputeOffset) < minStep,
           viewportHeight == lastComputeViewport {
            return
        }
        lastComputeOffset = contentOffset
        lastComputeViewport = viewportHeight

        let mountLow = contentOffset - mountMargin
        let mountHigh = contentOffset + viewportHeight + mountMargin
        let keepLow = contentOffset - keepMargin
        let keepHigh = contentOffset + viewportHeight + keepMargin
        let estimate = averageHeight()
        var y = topPadding + setupHeight
        for id in order {
            let measured = heights[id]
            let top = y
            let bottom = y + (measured ?? estimate)
            let state = mountState(for: id)

            let desired: Bool
            if measured == nil {
                desired = true // must render to be measured
            } else if state.isMounted {
                desired = bottom >= keepLow && top <= keepHigh // keep until past the wide band
            } else {
                desired = bottom >= mountLow && top <= mountHigh // mount at the narrow band
            }
            if state.isMounted != desired { state.isMounted = desired }
            y = bottom + rowSpacing
        }
    }

    /// Mounts every row. Called when culling turns off (a turn finished) so the
    /// whole transcript is live for reading — scrolling then never mounts
    /// anything, so trackpad momentum is never interrupted. Finished turns
    /// render collapsed, so this is a bounded one-shot layout, not per-frame.
    public func mountAll() {
        for id in order { setMounted(id, true) }
        lastComputeOffset = .nan
    }

    /// Forces the next `recompute` to run even if the offset barely moved.
    public func invalidateWindow() {
        lastComputeOffset = .nan
    }

    private func setMounted(_ id: UUID, _ mounted: Bool) {
        let state = mountState(for: id)
        if state.isMounted != mounted { state.isMounted = mounted }
    }

    /// Placeholder height for the offset walk over not-yet-measured rows.
    private func averageHeight() -> CGFloat {
        guard !heights.isEmpty else { return 120 }
        return heights.values.reduce(0, +) / CGFloat(heights.count)
    }
}
