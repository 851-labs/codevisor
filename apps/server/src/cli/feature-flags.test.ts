import { describe, expect, it } from "vitest"

import { flagsListCommand, flagsSetCommand } from "./feature-flags.js"
import { makeWorld } from "./support-test-support.js"
import type { CliDeps } from "./support.js"

type Answer = { status: number; body: unknown } | undefined

const world = (routes: Record<string, Answer>) => {
  const logs: string[] = []
  const errors: string[] = []
  const requests: { method: string; path: string; body?: unknown }[] = []
  const deps: CliDeps = {
    ...makeWorld({ env: { CODEVISOR_PORT: "49361" } }).deps,
    fetchJson: async (url, init) => {
      const method = init?.method ?? "GET"
      const path = new URL(url).pathname
      requests.push({ method, path, ...(init?.body === undefined ? {} : { body: init.body }) })
      return routes[`${method} ${path}`]
    },
    log: (line) => void logs.push(line),
    error: (line) => void errors.push(line)
  }
  return { deps, logs, errors, requests }
}

const developerMode = {
  id: "developerMode",
  title: "Developer Mode",
  description: "Adds a Developer section.",
  enabled: true
}
const gmail = {
  id: "gmailPlugin",
  title: "Gmail Plugin",
  description: "Shows Gmail.",
  enabled: false
}

describe("codevisor flags", () => {
  it("lists each flag with whether it is on, in aligned columns", async () => {
    const { deps, logs } = world({
      "GET /v1/feature-flags": { status: 200, body: { flags: [developerMode, gmail] } }
    })
    expect(await flagsListCommand(deps)).toBe(0)
    expect(logs).toEqual([
      "developerMode  on   Adds a Developer section.",
      "gmailPlugin    off  Shows Gmail."
    ])
  })

  it("turns a flag off through the server", async () => {
    const { deps, logs, requests } = world({
      "PUT /v1/feature-flags/developerMode": {
        status: 200,
        body: { ...developerMode, enabled: false }
      }
    })
    expect(await flagsSetCommand(deps, { flag: "developerMode", enabled: false })).toBe(0)
    expect(requests.at(-1)?.body).toEqual({ enabled: false })
    expect(logs).toEqual([
      "✓ Developer Mode is off. Your Codevisor apps sync it to your other machines."
    ])
  })

  it("passes the server's error through for an unknown flag", async () => {
    const { deps, errors } = world({
      "PUT /v1/feature-flags/robots": {
        status: 404,
        body: { error: "Unknown feature flag: robots. Known flags: gmailPlugin" }
      }
    })
    expect(await flagsSetCommand(deps, { flag: "robots", enabled: true })).toBe(1)
    expect(errors).toEqual([
      "Couldn't turn robots on: Unknown feature flag: robots. Known flags: gmailPlugin"
    ])
  })
})
