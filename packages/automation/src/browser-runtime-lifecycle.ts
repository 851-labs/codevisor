import type { ChildProcess } from "node:child_process"
import type { BrowserRuntime } from "./browser-cdp-engine.js"

export const serializedBrowserOperation = async <T>(
  active: BrowserRuntime,
  operation: () => Promise<T>
): Promise<T> => {
  let release = (): void => undefined
  const previous = active.queue
  active.queue = new Promise<void>((resolve) => {
    release = resolve
  })
  await previous
  try {
    return await operation()
  } finally {
    release()
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
