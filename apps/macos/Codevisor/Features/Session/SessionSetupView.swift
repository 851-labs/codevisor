import CodevisorCore
import CodevisorUI
import SwiftUI

#if DEBUG
  #Preview("Setup phases") {
    var running = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-12))
    running.appendLog(stream: "stderr", line: "Preparing worktree (new branch 'codevisor/fearless-raven')")
    running.appendLog(stream: "stdout", line: "git submodule update: cloning 12 repositories…")

    var done = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-64))
    done.succeed(durationMs: 60_000)

    var failed = SessionSetupPhase.worktree(startedAt: Date().addingTimeInterval(-3))
    failed.appendLog(stream: "stderr", line: "fatal: a branch named 'codevisor/fix-auth' already exists")
    failed.fail(message: "fatal: a branch named 'codevisor/fix-auth' already exists")

    let agent = SessionSetupPhase.startingAgent(named: "Claude Code", startedAt: Date().addingTimeInterval(-2))

    return ScrollView {
      SessionSetupView(phases: [running, done, failed, agent])
        .padding()
    }
    .frame(width: 640, height: 420)
  }
#endif
