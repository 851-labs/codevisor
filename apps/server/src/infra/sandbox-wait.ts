import type { Sandbox, WaitForSandboxResponse } from "@codevisor/api"

import { HttpFailure } from "../server-context.js"
import type { SandboxDeps } from "./sandboxes.js"

export const SANDBOX_WAIT_POLL_MS = 1000

const settledStates: ReadonlySet<Sandbox["state"]> = new Set(["ready", "failed", "archived"])

export const waitForSandbox = async (
  deps: Pick<SandboxDeps, "records" | "clock">,
  id: string,
  timeoutMs: number
): Promise<WaitForSandboxResponse> => {
  const deadline = deps.clock.now() + timeoutMs
  for (;;) {
    const sandbox = await deps.records.get(id)
    if (sandbox === undefined) throw new HttpFailure(404, `No sandbox ${id}`)
    if (settledStates.has(sandbox.state)) return { ...sandbox, timedOut: false }
    const left = deadline - deps.clock.now()
    if (left <= 0) return { ...sandbox, timedOut: true }
    await deps.clock.sleep(Math.min(SANDBOX_WAIT_POLL_MS, left))
  }
}
