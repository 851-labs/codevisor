import { describe, expect, it, vi } from "vitest"
import { monitorAppOwner } from "./serve.js"

describe("app-owned server lifecycle", () => {
  it("releases the database lease before stopping when its app exits", async () => {
    const order: string[] = []
    const release = vi.fn(async () => {
      order.push("release")
    })

    await new Promise<void>((resolve) => {
      monitorAppOwner({
        ownerPid: 42,
        lease: { release },
        intervalMilliseconds: 1,
        isAlive: () => false,
        stopProcess: () => {
          order.push("exit")
          resolve()
        }
      })
    })

    expect(release).toHaveBeenCalledOnce()
    expect(order).toEqual(["release", "exit"])
  })

  it("does not stop while the owning app is alive", async () => {
    const release = vi.fn(async () => undefined)
    const stopProcess = vi.fn()
    const cancel = monitorAppOwner({
      ownerPid: 42,
      lease: { release },
      intervalMilliseconds: 1,
      isAlive: () => true,
      stopProcess
    })

    await new Promise((resolve) => setTimeout(resolve, 10))
    cancel()

    expect(release).not.toHaveBeenCalled()
    expect(stopProcess).not.toHaveBeenCalled()
  })
})
