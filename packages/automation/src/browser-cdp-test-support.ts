import { vi } from "vitest"
import { CdpConnection } from "./browser-cdp.js"

/// Observe registration and completed event dispatch at the existing CDP boundary.
/// Install before constructing the provider; restore spies after each test.
export const observeCdp = () => {
  const registrations = new Map<string, () => void>()
  const events = new Set<{
    method: string
    matches: (params: Readonly<Record<string, unknown>>) => boolean
    resolve: () => void
  }>()
  const on = CdpConnection.prototype.on
  vi.spyOn(CdpConnection.prototype, "on").mockImplementation(function (
    this: CdpConnection,
    method,
    handler,
    sessionId
  ) {
    const stop = on.call(
      this,
      method,
      (params, event) => {
        handler(params, event)
        for (const waiting of events) {
          if (waiting.method === event.method && waiting.matches(params)) {
            events.delete(waiting)
            waiting.resolve()
          }
        }
      },
      sessionId
    )
    registrations.get(method)?.()
    registrations.delete(method)
    return stop
  })
  return {
    registered: (method: string) =>
      new Promise<void>((resolve) => registrations.set(method, resolve)),
    event: (method: string, matches = (_params: Readonly<Record<string, unknown>>) => true) =>
      new Promise<void>((resolve) => events.add({ method, matches, resolve }))
  }
}
