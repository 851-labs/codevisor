import { redactSecrets } from "@codevisor/agent-runtime"

import { failureMessage } from "../server-context.js"

export const logPromptFailure = (sessionId: string, cause: unknown): void => {
  console.error(
    JSON.stringify({
      event: "prompt_failed",
      sessionId,
      failure: redactSecrets(failureMessage(cause))
    })
  )
}
