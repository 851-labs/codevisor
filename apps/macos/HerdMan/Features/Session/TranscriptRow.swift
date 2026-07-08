import SwiftUI
import HerdManCore

extension EnvironmentValues {
    /// The session's disclosure store, injected at the transcript root. Nil in
    /// previews / detached contexts, where rows fall back to a throwaway store
    /// (no cross-session persistence, which previews don't need).
    @Entry var transcriptDisclosure: TranscriptDisclosureStore?

    /// Tool-call ids of subagents still running in the background after their
    /// spawning turn ended. Injected at the transcript root so a settled turn's
    /// worked section stays open and the subagent's label keeps shimmering
    /// until it leaves the set. Empty in previews / detached contexts.
    @Entry var runningSubagentToolCallIds: Set<String> = []
}

/// One settled transcript row, occlusion-culled.
///
/// When its `RowMountState.isMounted` is true (row within the viewport margin),
/// it renders the real `ConversationItemView` and reports its height to the
/// culler (spacer sizing + the offset walk that backs scroll capture/restore).
/// When culled it renders a fixed-height spacer of the last measured height, so
/// the total content size — and thus the scrollbar and every scroll offset — is
/// identical whether the row is content or spacer.
///
/// Reading `state.isMounted` is the ONLY observed dependency, so a window shift
/// re-renders just the handful of rows crossing the boundary, never the whole
/// transcript. Height is measured with `size.height` (fires on change, not per
/// scroll tick), so scrolling — even fully mounted — costs no per-row work.
struct TranscriptRow: View {
    let item: ConversationItem
    let culler: TranscriptCuller

    var body: some View {
        let state = culler.mountState(for: item.id)
        Group {
            if state.isMounted {
                ConversationItemView(item: item)
                    // Measure HEIGHT only (spacer sizing + the culler's offset
                    // walk). `size.height` fires when the row's height changes,
                    // NOT every scroll tick — so even a fully-mounted transcript
                    // has zero per-row callbacks while scrolling. Scroll
                    // capture/restore reads the culler's height model instead
                    // of per-row frames.
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: { height in
                        culler.setHeight(height, for: item.id)
                    }
            } else {
                Color.clear.frame(height: culler.height(for: item.id) ?? 0)
            }
        }
        // No blanket `.transaction { animation = nil }` here: every mount-flag
        // flip already happens inside a no-animation transaction at the call
        // site (recomputeCulling / mountAll), so the content↔spacer swap never
        // animates — while a blanket transaction would ALSO suppress the
        // legitimate tap-to-expand/collapse animations of mounted rows.
    }
}
