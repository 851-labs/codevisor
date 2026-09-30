import { describe, expect, it } from "vitest"

import {
  machinesAddCommand,
  machinesInviteCommand,
  machinesListCommand,
  machinesRemoveCommand
} from "./machines.js"
import type { CliDeps } from "./support.js"

type Answer = { status: number; body: unknown } | undefined

/// A CLI world whose loopback server answers from `routes` ("METHOD path").
const world = (routes: Record<string, Answer>) => {
  const logs: string[] = []
  const errors: string[] = []
  const requests: { method: string; path: string; body?: unknown }[] = []
  const deps = {
    fetchJson: async (url: string, init?: { method?: string; body?: unknown }) => {
      const method = init?.method ?? "GET"
      const path = new URL(url).pathname
      requests.push({ method, path, ...(init?.body === undefined ? {} : { body: init.body }) })
      return routes[`${method} ${path}`]
    },
    env: { CODEVISOR_PORT: "49361" },
    readTextFile: () => undefined,
    log: (line: string) => void logs.push(line),
    error: (line: string) => void errors.push(line)
  } as unknown as CliDeps
  return { deps, logs, errors, requests }
}

const hetzner = { id: "machine-h", name: "hetzner-1", online: true, isCurrent: false }

describe("codevisor machines", () => {
  it("prints only the invite code on stdout so it can be piped", async () => {
    const { deps, logs, errors } = world({
      "POST /v1/machines/invite": {
        status: 201,
        body: { code: "cvi1.x.y", expiresAt: "2100-01-01T00:10:00Z" }
      }
    })
    expect(await machinesInviteCommand(deps)).toBe(0)
    expect(logs).toEqual(["cvi1.x.y"])
    expect(errors.join("\n")).toContain("auth login --invite")
  })

  it("adds a host over SSH through the shared route", async () => {
    const { deps, logs, requests } = world({
      "POST /v1/machines/add": { status: 201, body: { machine: hetzner } }
    })
    expect(
      await machinesAddCommand(deps, { ssh: "root@h", name: "hetzner-1", sshPort: 2222 })
    ).toBe(0)
    expect(requests.at(-1)?.body).toEqual({ ssh: "root@h", name: "hetzner-1", sshPort: 2222 })
    expect(logs.at(-1)).toBe("✓ hetzner-1 is on your account (online).")
  })

  it("lists machines with where they came from", async () => {
    const { deps, logs } = world({
      "GET /v1/machines": {
        status: 200,
        body: {
          machines: [
            { id: "machine-s", name: "mac-studio", online: true, isCurrent: true },
            { ...hetzner, os: "linux", addedBy: "mac-studio" }
          ]
        }
      }
    })
    expect(await machinesListCommand(deps)).toBe(0)
    expect(logs).toEqual([
      "mac-studio  (this machine)  machine-s",
      "hetzner-1  online  linux  added by mac-studio  machine-h"
    ])
  })

  it("adds with only a destination, reports an offline result, and removes", async () => {
    const { deps, logs, requests } = world({
      "POST /v1/machines/add": { status: 201, body: { machine: { ...hetzner, online: false } } },
      "DELETE /v1/machines/hetzner-1": { status: 200, body: { machines: [] } }
    })
    expect(await machinesAddCommand(deps, { ssh: "box" })).toBe(0)
    expect(requests.at(-1)?.body).toEqual({ ssh: "box" })
    expect(logs.at(-1)).toBe("✓ hetzner-1 is on your account (offline).")
    expect(await machinesRemoveCommand(deps, { machine: "hetzner-1" })).toBe(0)
    expect(logs.at(-1)).toBe("✓ Removed hetzner-1 from your account.")
  })

  it("lists an offline machine", async () => {
    const { deps, logs } = world({
      "GET /v1/machines": { status: 200, body: { machines: [{ ...hetzner, online: false }] } }
    })
    expect(await machinesListCommand(deps)).toBe(0)
    expect(logs).toEqual(["hetzner-1  offline  machine-h"])
  })

  it("surfaces the server's reason when a command fails", async () => {
    const { deps, errors } = world({
      "POST /v1/machines/invite": { status: 502, body: { error: "the cloud is unavailable" } },
      "DELETE /v1/machines/hetzner%201": { status: 404, body: { error: 'No machine "hetzner 1"' } },
      "POST /v1/machines/add": { status: 502, body: null }
    })
    expect(await machinesInviteCommand(deps)).toBe(1)
    expect(await machinesAddCommand(deps, { ssh: "box" })).toBe(1)
    expect(await machinesRemoveCommand(deps, { machine: "hetzner 1" })).toBe(1)
    expect(await machinesListCommand(deps)).toBe(1)
    expect(errors).toEqual([
      "Couldn't create an invite: the cloud is unavailable",
      "Couldn't add box: the server answered HTTP 502",
      'Couldn\'t remove hetzner 1: No machine "hetzner 1"',
      "Couldn't list machines: Codevisor server is not running on port 49361; start it with: codevisor start"
    ])
  })
})
