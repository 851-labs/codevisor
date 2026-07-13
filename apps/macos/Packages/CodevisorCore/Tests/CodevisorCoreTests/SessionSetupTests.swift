import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@Suite("Session setup phases")
struct SessionSetupTests {
    private func envelope(
        kind: String = "worktree.setup",
        subjectId: String = "wt-1",
        payload: JSONValue
    ) -> ServerEventEnvelope {
        ServerEventEnvelope(
            id: 1,
            serverId: "local",
            kind: kind,
            subjectId: subjectId,
            createdAt: "2026-07-03T00:00:00.000Z",
            payload: payload
        )
    }

    @Test("Decodes worktree setup lifecycle events")
    func decodesLifecycle() {
        #expect(WorktreeSetupEvent.from(envelope(payload: ["state": "started"]), worktreeId: "wt-1") == .started)
        #expect(
            WorktreeSetupEvent.from(
                envelope(payload: [
                    "state": "log", "stream": "stderr",
                    "line": "Preparing worktree (new branch 'codevisor/fix-auth')"
                ]),
                worktreeId: "WT-1"
            ) == .log(stream: "stderr", line: "Preparing worktree (new branch 'codevisor/fix-auth')")
        )
        #expect(
            WorktreeSetupEvent.from(
                envelope(payload: ["state": "completed", "durationMs": 60000]),
                worktreeId: "wt-1"
            ) == .completed(durationMs: 60000)
        )
        #expect(
            WorktreeSetupEvent.from(
                envelope(payload: ["state": "failed", "message": "fatal: branch exists"]),
                worktreeId: "wt-1"
            ) == .failed(message: "fatal: branch exists", durationMs: nil)
        )
    }

    @Test("Fills defaults for sparse payloads")
    func decodesDefaults() {
        #expect(
            WorktreeSetupEvent.from(envelope(payload: ["state": "log", "line": "hello"]), worktreeId: "wt-1")
                == .log(stream: "stdout", line: "hello")
        )
        #expect(
            WorktreeSetupEvent.from(envelope(payload: ["state": "failed"]), worktreeId: "wt-1")
                == .failed(message: "Worktree setup failed.", durationMs: nil)
        )
    }

    @Test("Ignores other kinds, subjects, and unknown or malformed states")
    func ignoresUnrelated() {
        #expect(WorktreeSetupEvent.from(
            envelope(kind: "session.output", payload: ["state": "log", "line": "x"]), worktreeId: "wt-1"
        ) == nil)
        #expect(WorktreeSetupEvent.from(
            envelope(subjectId: "wt-2", payload: ["state": "started"]), worktreeId: "wt-1"
        ) == nil)
        #expect(WorktreeSetupEvent.from(envelope(payload: ["state": "unknown"]), worktreeId: "wt-1") == nil)
        #expect(WorktreeSetupEvent.from(envelope(payload: ["state": "log"]), worktreeId: "wt-1") == nil)
        #expect(WorktreeSetupEvent.from(envelope(payload: ["other": true]), worktreeId: "wt-1") == nil)
    }

    @Test("Phase lifecycle: logs, success timing, failure")
    func phaseLifecycle() {
        let start = Date(timeIntervalSince1970: 1_000)
        var phase = SessionSetupPhase.worktree(startedAt: start)
        #expect(phase.isRunning)
        #expect(phase.duration == nil)
        #expect(phase.failureMessage == nil)

        phase.appendLog(stream: "stderr", line: "Preparing worktree")
        phase.appendLog(stream: "stdout", line: "git submodule update")
        #expect(phase.logs.map(\.id) == [0, 1])
        #expect(phase.logs.map(\.text) == ["Preparing worktree", "git submodule update"])

        // A server-measured duration wins over local clocks.
        phase.succeed(durationMs: 60_000, at: start.addingTimeInterval(99))
        #expect(!phase.isRunning)
        #expect(phase.outcome == .succeeded)
        #expect(phase.duration == 60)

        var failed = SessionSetupPhase.worktree(startedAt: start)
        failed.fail(message: "fatal: branch exists", at: start.addingTimeInterval(2))
        #expect(failed.failureMessage == "fatal: branch exists")
        #expect(failed.duration == 2)
    }

    @Test("Phase titles cover worktree setup and agent start")
    func phaseTitles() {
        let worktree = SessionSetupPhase.worktree()
        #expect(worktree.id == SessionSetupPhase.worktreePhaseId)
        #expect(worktree.activeTitle == "Setting up worktree")
        #expect(worktree.completedTitle == "Set up worktree")
        #expect(worktree.failedTitle == "Could not set up worktree")

        let agent = SessionSetupPhase.startingAgent(named: "Claude Code")
        #expect(agent.id == SessionSetupPhase.agentPhaseId)
        #expect(agent.activeTitle == "Starting Claude Code")
        #expect(agent.completedTitle == "Started Claude Code")
        #expect(agent.failedTitle == "Could not start Claude Code")
    }
}
