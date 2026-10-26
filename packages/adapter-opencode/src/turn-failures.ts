import type { AcpPromptResult } from "@codevisor/adapter-acp"
import {
  harnessFailureStop,
  resetTimeIn,
  usageLimitStop,
  type HarnessFailure
} from "@codevisor/agent-runtime"

import type { TurnErrorInfo } from "./translate.js"
import { isOpenCodeUsageLimitMessage } from "./usage-limits.js"

export const failedTurnResult = (error: TurnErrorInfo): AcpPromptResult => {
  if (needsSignIn(error)) return { stopReason: "end_turn", stopKind: "authRequired" }
  if (isOpenCodeUsageLimitMessage(error.message))
    return { stopReason: "end_turn", ...usageLimitStop(error.message, resetTimeIn(error.message)) }

  return { stopReason: "end_turn", ...harnessFailureStop(harnessFailure(error)) }
}

const forbiddenStatus = 403

const needsSignIn = (error: TurnErrorInfo): boolean =>
  error.type === "provider.auth" && error.status !== forbiddenStatus

const harnessFailure = (error: TurnErrorInfo): HarnessFailure => ({
  message: error.message || "OpenCode prompt failed",
  status: error.status,
  code: error.type
})
