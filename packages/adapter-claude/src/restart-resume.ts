import type { InterruptedTurnResume } from "@codevisor/agent-runtime"

import type { ClaudeQuery } from "./session.js"
import { compareVersions } from "./versions.js"

const RESTART_RESUME_MINIMUM_VERSION = "2.1.311"
const RESTART_RESUME_REASON = "host_draining"

export const supportsRestartResume = (version: string): boolean =>
  compareVersions(version, RESTART_RESUME_MINIMUM_VERSION) >= 0

export const restartResumeEnv = (
  resume: InterruptedTurnResume | undefined
): Record<string, string> =>
  resume === undefined
    ? {}
    : {
        CLAUDE_CODE_RESUME_INTERRUPTED_TURN: "1",
        CLAUDE_CODE_RESUME_PROMPT: resume.notice,
        CLAUDE_CODE_RESUME_REASON: RESTART_RESUME_REASON
      }

export const withoutRestartResumeEnv = (
  env: Record<string, string | undefined>
): Record<string, string | undefined> => {
  const {
    CLAUDE_CODE_RESUME_INTERRUPTED_TURN: _resume,
    CLAUDE_CODE_RESUME_PROMPT: _prompt,
    CLAUDE_CODE_RESUME_REASON: _reason,
    ...kept
  } = env
  return kept
}

export const endSessionRequest = (q: ClaudeQuery): (() => Promise<unknown>) | undefined => {
  const request: unknown = Reflect.get(q, "request")
  if (typeof request !== "function") return undefined

  return () =>
    Reflect.apply(request, q, [{ reason: RESTART_RESUME_REASON, subtype: "end_session" }])
}
