import { delay } from "./browser-cdp.js"
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
  for (const dispose of active.eventDisposers.splice(0)) dispose()
  if (active.owned) {
    await active.connection.send("Browser.close").catch(() => undefined)
    if (active.processHandle !== undefined && active.processHandle.exitCode === null) {
      await Promise.race([
        new Promise<void>((resolve) => active.processHandle!.once("exit", () => resolve())),
        delay(500)
      ])
    }
    if (active.processHandle !== undefined && active.processHandle.exitCode === null) {
      active.processHandle.kill("SIGTERM")
      await Promise.race([
        new Promise<void>((resolve) => active.processHandle!.once("exit", () => resolve())),
        delay(1_500)
      ])
    }
  }
  await active.connection.close().catch(() => undefined)
}
