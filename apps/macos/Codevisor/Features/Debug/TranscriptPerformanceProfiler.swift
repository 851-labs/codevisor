import AppKit
import OSLog
import QuartzCore

struct TranscriptPerformanceIdentity: Hashable, Sendable {
    let rowKey: String
    let kind: String
}

enum TranscriptPerformancePhase: String, Sendable {
    case geometry = "geometry"
    case windowReconcile = "window reconcile"
    case hostReuse = "host reuse"
    case hostConstruction = "host construction"
    case hostPreparation = "host preparation"
    case hostInsertion = "host insertion"
    case hostPosition = "host positioning"
    case rootConstruction = "root construction"
    case rootInstall = "root install"
    case runwayLayout = "runway layout"
    case visibleLayout = "visible layout"
    case hostLayout = "host layout"
    case sizeThatFits = "sizeThatFits"
    case hostRetirement = "host retirement"
    case windowPromotion = "window promotion"
    case windowScheduling = "window scheduling"
    case windowUpdate = "window update"
    case visibleFrame = "visible frame"
}

struct TranscriptPerformancePhaseSummary: Identifiable, Equatable, Sendable {
    var id: String { phase }

    let phase: String
    let operationCount: Int
    let totalExclusiveMilliseconds: Double
    let worstInclusiveMilliseconds: Double
    let worstExclusiveMilliseconds: Double
}

struct TranscriptPerformanceKindSummary: Identifiable, Equatable, Sendable {
    var id: String { kind }

    let kind: String
    let operationCount: Int
    let totalExclusiveMilliseconds: Double
    let averageExclusiveMilliseconds: Double
    let worstExclusiveMilliseconds: Double
}

struct TranscriptPerformanceHotspot: Identifiable, Equatable, Sendable {
    var id: String { rowKey }

    let rowKey: String
    let kind: String
    let excessFrameMilliseconds: Double
    let worstFrameMilliseconds: Double
    let measuredWorkMilliseconds: Double
    let worstOperationMilliseconds: Double
    let worstPhase: String
}

struct TranscriptPerformanceSnapshot: Equatable, Sendable {
    static let empty = Self(
        frameCount: 0,
        p99FrameMilliseconds: 0,
        medianProfiledWorkMilliseconds: 0,
        totalProfiledWorkMilliseconds: 0,
        onePercentLowFPS: 0,
        missedVSyncPercent: 0,
        hitchTimePercent: 0,
        hotspots: [],
        phases: [],
        kinds: []
    )

    let frameCount: Int
    let p99FrameMilliseconds: Double
    /// Median exclusive time inside instrumented transcript spans per display
    /// frame. Unlike frame duration, this can improve below one vsync and is a
    /// useful steady-state/energy metric on a 120 Hz display.
    let medianProfiledWorkMilliseconds: Double
    let totalProfiledWorkMilliseconds: Double
    let onePercentLowFPS: Double
    let missedVSyncPercent: Double
    let hitchTimePercent: Double
    let hotspots: [TranscriptPerformanceHotspot]
    let phases: [TranscriptPerformancePhaseSummary]
    let kinds: [TranscriptPerformanceKindSummary]
}

/// Development-only correlation between native display frames and transcript
/// row work. Recording is dormant unless the Performance HUD is attached to
/// the same window, keeping ordinary development runs free of profiling work.
@MainActor
final class TranscriptPerformanceProfiler {
    static let shared = TranscriptPerformanceProfiler()

    struct WorkToken {
        fileprivate let windowNumber: Int
        fileprivate let identity: TranscriptPerformanceIdentity
        fileprivate let phase: TranscriptPerformancePhase
        fileprivate let startedAt: CFTimeInterval
        fileprivate let signpostID: OSSignpostID
        fileprivate let sequence: UInt64
    }

    private struct WorkSample {
        let identity: TranscriptPerformanceIdentity
        let phase: TranscriptPerformancePhase
        let inclusiveDurationMilliseconds: Double
        let exclusiveDurationMilliseconds: Double
    }

    private struct ActiveWork {
        let sequence: UInt64
        var childDurationMilliseconds = 0.0
    }

    private struct PhaseAggregate {
        var operationCount = 0
        var totalExclusiveMilliseconds = 0.0
        var worstInclusiveMilliseconds = 0.0
        var worstExclusiveMilliseconds = 0.0
    }

    private struct HotspotAggregate {
        var excessFrameMilliseconds = 0.0
        var worstFrameMilliseconds = 0.0
        var measuredWorkMilliseconds = 0.0
        var worstOperationMilliseconds = 0.0
        var worstPhase = TranscriptPerformancePhase.visibleFrame
    }

    private struct KindAggregate {
        var operationCount = 0
        var totalExclusiveMilliseconds = 0.0
        var worstExclusiveMilliseconds = 0.0
    }

    private struct WindowSession {
        var isEnabled = false
        var isScrolling = false
        var targetFrameMilliseconds = 1000.0 / 60.0
        var lastFrameTimestamp: TimeInterval?
        var lastSnapshotTimestamp: TimeInterval = 0
        var pendingWork: [WorkSample] = []
        var visibleRows: [TranscriptPerformanceIdentity] = []
        var frameDurations: [Double] = []
        var profiledWorkDurations: [Double] = []
        var missedVSyncCount = 0
        var expectedVSyncCount = 0
        var hitchMilliseconds = 0.0
        var totalScrollMilliseconds = 0.0
        var hotspots: [TranscriptPerformanceIdentity: HotspotAggregate] = [:]
        var phases: [TranscriptPerformancePhase: PhaseAggregate] = [:]
        var kinds: [String: KindAggregate] = [:]
    }

    private let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.851labs.Codevisor",
        category: "TranscriptPerformance"
    )
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.851labs.Codevisor",
        category: "TranscriptPerformance"
    )
    private var sessions: [Int: WindowSession] = [:]
    private var activeWorkByWindow: [Int: [ActiveWork]] = [:]
    private var nextWorkSequence: UInt64 = 0

    private init() {}

    func setEnabled(
        _ enabled: Bool,
        windowNumber: Int,
        maximumFramesPerSecond: Int
    ) {
        guard enabled else {
            sessions.removeValue(forKey: windowNumber)
            activeWorkByWindow.removeValue(forKey: windowNumber)
            return
        }
        var session = WindowSession()
        session.isEnabled = true
        session.targetFrameMilliseconds = 1000.0 / Double(max(1, maximumFramesPerSecond))
        sessions[windowNumber] = session
        activeWorkByWindow[windowNumber] = []
    }

    func isEnabled(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return sessions[window.windowNumber]?.isEnabled == true
    }

    func beginScrolling(in window: NSWindow?) {
        guard let window, var session = sessions[window.windowNumber] else { return }
        let target = session.targetFrameMilliseconds
        session = WindowSession()
        session.isEnabled = true
        session.isScrolling = true
        session.targetFrameMilliseconds = target
        sessions[window.windowNumber] = session
        activeWorkByWindow[window.windowNumber] = []
    }

    func endScrolling(in window: NSWindow?) {
        guard let window, var session = sessions[window.windowNumber] else { return }
        session.isScrolling = false
        sessions[window.windowNumber] = session
        logSummary(snapshot(for: session))
    }

    func setVisibleRows(
        _ rows: [TranscriptPerformanceIdentity],
        in window: NSWindow?
    ) {
        guard let window, var session = sessions[window.windowNumber] else { return }
        session.visibleRows = rows
        sessions[window.windowNumber] = session
    }

    func begin(
        in window: NSWindow?,
        identity: TranscriptPerformanceIdentity,
        phase: TranscriptPerformancePhase
    ) -> WorkToken? {
        guard let window, sessions[window.windowNumber]?.isEnabled == true else { return nil }
        nextWorkSequence &+= 1
        let sequence = nextWorkSequence
        activeWorkByWindow[window.windowNumber, default: []].append(
            ActiveWork(sequence: sequence)
        )
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(
            .begin,
            log: signpostLog,
            name: "Transcript Work",
            signpostID: signpostID,
            "%{public}s | %{public}s | %{public}s",
            phase.rawValue,
            identity.kind,
            identity.rowKey
        )
        return WorkToken(
            windowNumber: window.windowNumber,
            identity: identity,
            phase: phase,
            startedAt: CACurrentMediaTime(),
            signpostID: signpostID,
            sequence: sequence
        )
    }

    func end(_ token: WorkToken?) {
        guard let token else { return }
        let duration = (CACurrentMediaTime() - token.startedAt) * 1_000
        let exclusiveDuration = finishActiveWork(token, inclusiveDuration: duration)
        os_signpost(
            .end,
            log: signpostLog,
            name: "Transcript Work",
            signpostID: token.signpostID,
            "%{public}s | %{public}s | %{public}s | %.3f ms",
            token.phase.rawValue,
            token.identity.kind,
            token.identity.rowKey,
            duration
        )
        guard var session = sessions[token.windowNumber] else { return }
        session.pendingWork.append(
            WorkSample(
                identity: token.identity,
                phase: token.phase,
                inclusiveDurationMilliseconds: duration,
                exclusiveDurationMilliseconds: exclusiveDuration
            ))
        if session.pendingWork.count > 512 {
            session.pendingWork.removeFirst(session.pendingWork.count - 512)
        }
        sessions[token.windowNumber] = session
    }

    func measure<Result>(
        in window: NSWindow?,
        identity: TranscriptPerformanceIdentity,
        phase: TranscriptPerformancePhase,
        _ work: () throws -> Result
    ) rethrows -> Result {
        let token = begin(in: window, identity: identity, phase: phase)
        defer { end(token) }
        return try work()
    }

    /// Nested spans are useful for Instruments but must not be counted twice
    /// when attributing a slow display frame. Keep both numbers: inclusive
    /// duration explains how long an operation blocked its caller, while
    /// exclusive duration identifies which split phase actually owned the
    /// main-thread work.
    private func finishActiveWork(
        _ token: WorkToken,
        inclusiveDuration: Double
    ) -> Double {
        guard var stack = activeWorkByWindow[token.windowNumber],
            let index = stack.lastIndex(where: { $0.sequence == token.sequence })
        else { return inclusiveDuration }
        let active = stack.remove(at: index)
        let exclusiveDuration = max(0, inclusiveDuration - active.childDurationMilliseconds)
        if index > 0 {
            stack[index - 1].childDurationMilliseconds += inclusiveDuration
        }
        activeWorkByWindow[token.windowNumber] = stack
        return exclusiveDuration
    }

    func recordDisplayFrame(
        windowNumber: Int,
        timestamp: TimeInterval
    ) -> TranscriptPerformanceSnapshot? {
        guard var session = sessions[windowNumber] else { return nil }
        defer { sessions[windowNumber] = session }
        guard let previousTimestamp = session.lastFrameTimestamp else {
            session.lastFrameTimestamp = timestamp
            session.pendingWork.removeAll(keepingCapacity: true)
            return publishSnapshotIfDue(for: &session, at: timestamp)
        }
        session.lastFrameTimestamp = timestamp

        let frameMilliseconds = (timestamp - previousTimestamp) * 1_000
        guard frameMilliseconds > 0, frameMilliseconds < 2_000 else {
            session.pendingWork.removeAll(keepingCapacity: true)
            return publishSnapshotIfDue(for: &session, at: timestamp)
        }
        guard session.isScrolling else {
            session.pendingWork.removeAll(keepingCapacity: true)
            return publishSnapshotIfDue(for: &session, at: timestamp)
        }

        session.frameDurations.append(frameMilliseconds)
        if session.frameDurations.count > 2_400 {
            session.frameDurations.removeFirst(session.frameDurations.count - 2_400)
        }
        session.totalScrollMilliseconds += frameMilliseconds

        let target = session.targetFrameMilliseconds
        let occupiedVSyncs = max(1, Int((frameMilliseconds / target).rounded()))
        session.expectedVSyncCount += occupiedVSyncs
        session.missedVSyncCount += max(0, occupiedVSyncs - 1)
        let excess = max(0, frameMilliseconds - target)
        session.hitchMilliseconds += excess

        var workByIdentity: [TranscriptPerformanceIdentity: Double] = [:]
        var profiledWorkMilliseconds = 0.0
        for sample in session.pendingWork {
            let exclusiveDuration = sample.exclusiveDurationMilliseconds
            profiledWorkMilliseconds += exclusiveDuration
            workByIdentity[sample.identity, default: 0] += exclusiveDuration
            var aggregate = session.hotspots[sample.identity, default: HotspotAggregate()]
            aggregate.measuredWorkMilliseconds += exclusiveDuration
            if exclusiveDuration > aggregate.worstOperationMilliseconds {
                aggregate.worstOperationMilliseconds = exclusiveDuration
                aggregate.worstPhase = sample.phase
            }
            aggregate.worstFrameMilliseconds = max(
                aggregate.worstFrameMilliseconds,
                frameMilliseconds
            )
            session.hotspots[sample.identity] = aggregate

            var phaseAggregate = session.phases[sample.phase, default: PhaseAggregate()]
            phaseAggregate.operationCount += 1
            phaseAggregate.totalExclusiveMilliseconds += exclusiveDuration
            phaseAggregate.worstInclusiveMilliseconds = max(
                phaseAggregate.worstInclusiveMilliseconds,
                sample.inclusiveDurationMilliseconds
            )
            phaseAggregate.worstExclusiveMilliseconds = max(
                phaseAggregate.worstExclusiveMilliseconds,
                exclusiveDuration
            )
            session.phases[sample.phase] = phaseAggregate

            var kindAggregate = session.kinds[sample.identity.kind, default: KindAggregate()]
            kindAggregate.operationCount += 1
            kindAggregate.totalExclusiveMilliseconds += exclusiveDuration
            kindAggregate.worstExclusiveMilliseconds = max(
                kindAggregate.worstExclusiveMilliseconds,
                exclusiveDuration
            )
            session.kinds[sample.identity.kind] = kindAggregate
        }
        session.profiledWorkDurations.append(profiledWorkMilliseconds)
        if session.profiledWorkDurations.count > 2_400 {
            session.profiledWorkDurations.removeFirst(
                session.profiledWorkDurations.count - 2_400
            )
        }

        if excess > 0 {
            if !workByIdentity.isEmpty {
                let totalMeasuredWork = max(0.001, workByIdentity.values.reduce(0, +))
                for (identity, duration) in workByIdentity {
                    var aggregate = session.hotspots[identity, default: HotspotAggregate()]
                    aggregate.excessFrameMilliseconds += excess * duration / totalMeasuredWork
                    session.hotspots[identity] = aggregate
                }
            } else if !session.visibleRows.isEmpty {
                let share = excess / Double(session.visibleRows.count)
                for identity in session.visibleRows {
                    var aggregate = session.hotspots[identity, default: HotspotAggregate()]
                    aggregate.excessFrameMilliseconds += share
                    aggregate.worstFrameMilliseconds = max(
                        aggregate.worstFrameMilliseconds,
                        frameMilliseconds
                    )
                    session.hotspots[identity] = aggregate
                }
            }
        }
        session.pendingWork.removeAll(keepingCapacity: true)
        return publishSnapshotIfDue(for: &session, at: timestamp)
    }

    private func publishSnapshotIfDue(
        for session: inout WindowSession,
        at timestamp: TimeInterval
    ) -> TranscriptPerformanceSnapshot? {
        guard timestamp - session.lastSnapshotTimestamp >= 0.25 else { return nil }
        session.lastSnapshotTimestamp = timestamp
        return snapshot(for: session)
    }

    private func snapshot(for session: WindowSession) -> TranscriptPerformanceSnapshot {
        let sortedFrames = session.frameDurations.sorted()
        let p99Index = max(0, Int(ceil(Double(sortedFrames.count) * 0.99)) - 1)
        let p99 = sortedFrames.isEmpty ? 0 : sortedFrames[p99Index]
        let sortedProfiledWork = session.profiledWorkDurations.sorted()
        let medianProfiledWork = percentile(0.5, in: sortedProfiledWork)
        let hotspots = session.hotspots.map { identity, aggregate in
            TranscriptPerformanceHotspot(
                rowKey: identity.rowKey,
                kind: identity.kind,
                excessFrameMilliseconds: aggregate.excessFrameMilliseconds,
                worstFrameMilliseconds: aggregate.worstFrameMilliseconds,
                measuredWorkMilliseconds: aggregate.measuredWorkMilliseconds,
                worstOperationMilliseconds: aggregate.worstOperationMilliseconds,
                worstPhase: aggregate.worstPhase.rawValue
            )
        }
        .sorted {
            if $0.excessFrameMilliseconds != $1.excessFrameMilliseconds {
                return $0.excessFrameMilliseconds > $1.excessFrameMilliseconds
            }
            return $0.worstOperationMilliseconds > $1.worstOperationMilliseconds
        }
        let phases = session.phases.map { phase, aggregate in
            TranscriptPerformancePhaseSummary(
                phase: phase.rawValue,
                operationCount: aggregate.operationCount,
                totalExclusiveMilliseconds: aggregate.totalExclusiveMilliseconds,
                worstInclusiveMilliseconds: aggregate.worstInclusiveMilliseconds,
                worstExclusiveMilliseconds: aggregate.worstExclusiveMilliseconds
            )
        }
        .sorted {
            if $0.worstExclusiveMilliseconds != $1.worstExclusiveMilliseconds {
                return $0.worstExclusiveMilliseconds > $1.worstExclusiveMilliseconds
            }
            return $0.totalExclusiveMilliseconds > $1.totalExclusiveMilliseconds
        }
        let kinds = session.kinds.map { kind, aggregate in
            TranscriptPerformanceKindSummary(
                kind: kind,
                operationCount: aggregate.operationCount,
                totalExclusiveMilliseconds: aggregate.totalExclusiveMilliseconds,
                averageExclusiveMilliseconds: aggregate.operationCount > 0
                    ? aggregate.totalExclusiveMilliseconds / Double(aggregate.operationCount)
                    : 0,
                worstExclusiveMilliseconds: aggregate.worstExclusiveMilliseconds
            )
        }
        .sorted {
            if $0.totalExclusiveMilliseconds != $1.totalExclusiveMilliseconds {
                return $0.totalExclusiveMilliseconds > $1.totalExclusiveMilliseconds
            }
            return $0.worstExclusiveMilliseconds > $1.worstExclusiveMilliseconds
        }
        return TranscriptPerformanceSnapshot(
            frameCount: sortedFrames.count,
            p99FrameMilliseconds: p99,
            medianProfiledWorkMilliseconds: medianProfiledWork,
            totalProfiledWorkMilliseconds: session.kinds.values.reduce(0) {
                $0 + $1.totalExclusiveMilliseconds
            },
            onePercentLowFPS: p99 > 0 ? 1_000 / p99 : 0,
            missedVSyncPercent: session.expectedVSyncCount > 0
                ? Double(session.missedVSyncCount) / Double(session.expectedVSyncCount) * 100
                : 0,
            hitchTimePercent: session.totalScrollMilliseconds > 0
                ? session.hitchMilliseconds / session.totalScrollMilliseconds * 100
                : 0,
            hotspots: Array(hotspots.prefix(8)),
            phases: phases,
            kinds: kinds
        )
    }

    private func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let bounded = min(1, max(0, percentile))
        let index = max(0, Int(ceil(Double(sortedValues.count) * bounded)) - 1)
        return sortedValues[index]
    }

}

private extension TranscriptPerformanceProfiler {
    func logSummary(_ snapshot: TranscriptPerformanceSnapshot) {
        guard snapshot.frameCount > 0 else { return }
        let hotspotSummary = snapshot.hotspots.prefix(5).map {
            "\($0.kind) [\($0.rowKey)] excess=\(format($0.excessFrameMilliseconds))ms "
                + "worstFrame=\(format($0.worstFrameMilliseconds))ms "
                + "worstWork=\(format($0.worstOperationMilliseconds))ms/\($0.worstPhase)"
        }.joined(separator: "; ")
        let summary =
            "Transcript scroll: p99=\(format(snapshot.p99FrameMilliseconds))ms "
            + "p50work=\(format(snapshot.medianProfiledWorkMilliseconds))ms "
            + "totalWork=\(format(snapshot.totalProfiledWorkMilliseconds))ms "
            + "1%low=\(format(snapshot.onePercentLowFPS))fps "
            + "missed=\(format(snapshot.missedVSyncPercent))% "
            + "hitch=\(format(snapshot.hitchTimePercent))% "
            + "hotspots=\(hotspotSummary)"
        logger.info("\(summary, privacy: .public)")
        let phaseSummary = snapshot.phases.map {
            "\($0.phase) max=\(format($0.worstInclusiveMilliseconds))ms "
                + "self=\(format($0.worstExclusiveMilliseconds))ms "
                + "totalSelf=\(format($0.totalExclusiveMilliseconds))ms/\($0.operationCount)x"
        }.joined(separator: "; ")
        logger.info("Transcript phases: \(phaseSummary, privacy: .public)")
        let kindSummary = snapshot.kinds.prefix(12).map {
            "\($0.kind) selfTotal=\(format($0.totalExclusiveMilliseconds))ms "
                + "avg=\(format($0.averageExclusiveMilliseconds))ms "
                + "max=\(format($0.worstExclusiveMilliseconds))ms/\($0.operationCount)x"
        }.joined(separator: "; ")
        logger.info("Transcript kinds: \(kindSummary, privacy: .public)")
    }

    func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
