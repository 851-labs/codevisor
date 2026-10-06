import type { ChildProcess } from "node:child_process"

import type { BrowserRuntime } from "./browser-cdp-engine.js"

export const serializedBrowserOperation = async <T>(
  active: BrowserRuntime,
  operation: () => Promise<T>
): Promise<T> => {
  const { promise, resolve: release } = Promise.withResolvers<void>()
  const previous = active.queue
  active.queue = promise
  await previous
  try {
    return await operation()
  } finally {
    release()
  }
}

/// Chrome removes a closed tab a moment after `Target.closeTarget` answers.
/// Waits, briefly, until none of `targetIds` is listed anymore, so whatever
/// lists tabs next (the agent's next turn, or the user) doesn't see a tab
/// that is already closing. Gives up quietly at the deadline.
export const waitForTargetsClosed = async (
  active: BrowserRuntime,
  targetIds: ReadonlyArray<string>,
  timeoutMs = 2_000,
  intervalMs = 50
): Promise<void> => {
  const deadline = Date.now() + timeoutMs
  while (targetIds.length > 0) {
    const listed = await active.connection
      .send<{ targetInfos?: ReadonlyArray<{ targetId: string }> }>("Target.getTargets")
      .then(({ targetInfos }) => new Set((targetInfos ?? []).map((info) => info.targetId)))
      .catch(() => new Set<string>())
    if (!targetIds.some((targetId) => listed.has(targetId)) || Date.now() >= deadline) return
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }
}

export const closeBrowserRuntime = async (active: BrowserRuntime): Promise<void> => {
  await active.queue.catch(() => undefined)
  await active.synchronizeCookies?.().catch(() => undefined)
  for (const dispose of active.eventDisposers.splice(0)) dispose()
  if (active.owned) {
    // Arm before Browser.close: the process may exit before CDP replies.
    const exited = active.processHandle && browserProcessExit(active.processHandle)
    const requested = active.connection.send("Browser.close").catch(() => undefined)
    await (exited ?? requested)
  }
  await active.connection.close().catch(() => undefined)
}

const browserProcessExit = (child: ChildProcess): Promise<void> => {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve()
  return new Promise<void>((resolve) => {
    const terminate = setTimeout(() => child.kill("SIGTERM"), 500)
    const kill = setTimeout(() => child.kill("SIGKILL"), 2_000)
    child.once("exit", () => {
      clearTimeout(terminate)
      clearTimeout(kill)
      resolve()
    })
  })
}
