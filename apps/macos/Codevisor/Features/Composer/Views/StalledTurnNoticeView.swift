import CodevisorCore
import CodevisorUI
import SwiftUI

/// The stalled-turn escape hatch, shown in the composer cluster's notice rail
/// once a turn has gone quiet for the model's stall interval.
///
/// Deliberately its OWN view rather than inline in the notice rail or the
/// composer card: `noteProviderActivity` writes `isTakingLongerThanExpected`
/// and `providerActivityPhase` as the turn streams, and Observation scopes
/// invalidation to the body that read the property. Reading them from
/// `ChatScreen`'s body would put the whole composer cluster — text view,
/// harness menus, glass surface — back on the per-event diff; reading them
/// here keeps that cost to this one caption row.
///
/// This rail is the sole delayed-stall surface and owns the recovery action;
/// the transcript keeps its ordinary shimmer instead of escalating its copy.
struct StalledTurnNoticeView: View {
    let controller: SessionController

    var body: some View {
        if controller.isTakingLongerThanExpected {
            ComposerNoticeRail(
                "Taking longer than expected"
                    + (controller.providerActivityPhase.map { " during \($0.label)" } ?? ""),
                kind: .warning,
                systemImage: "clock.badge.exclamationmark",
                actionTitle: "Stop and reconnect",
                action: {
                    Task {
                        await controller.stop()
                        if !controller.isSending {
                            await controller.reconnect()
                        }
                    }
                }
            )
        }
    }
}
