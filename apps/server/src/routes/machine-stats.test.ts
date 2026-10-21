import { describe, expect, it } from "vitest"

import type { MachineStatsSampler } from "../infra/machine-stats.js"
import { makeServices, start, startWithApp } from "../test-support.js"

describe("machine stats route", () => {
  it("serves the machine's stats", async () => {
    const stats = {
      sampledAt: "2026-10-20T12:00:00.000Z",
      uptimeSeconds: 60,
      cpu: {
        cores: 8,
        usedPercent: 12,
        history: [{ at: "2026-10-20T12:00:00.000Z", usedPercent: 12 }]
      },
      memory: { usedBytes: 6, totalBytes: 16 }
    }
    const machineStats: MachineStatsSampler = { read: async () => stats, stop: () => undefined }
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, machineStats })

    const response = await fetch(`${server.url}/v1/machine/stats`)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual(stats)
    expect((await fetch(`${server.url}/v1/machine/stats`, { method: "POST" })).status).toBe(404)
  })

  it("reports stats unavailable without a sampler", async () => {
    const { server } = await start()
    expect((await fetch(`${server.url}/v1/machine/stats`)).status).toBe(501)
  })
})
