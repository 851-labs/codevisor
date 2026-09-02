import { describe, expect, it } from "vitest"
import { NativeMcpError } from "@codevisor/mcp"
import {
  jsonRequest,
  makeServices,
  nativeMcpRemoval,
  nativeMcpScan,
  nativeMcpStub,
  runningServers,
  skillsScan,
  skillsStub,
  startWithApp
} from "../test-support.js"

describe("native MCP and skills routes", () => {
  it("serves scans from the configured managers", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp({
      ...services,
      nativeMcp: nativeMcpStub([]),
      skills: skillsStub([])
    })
    runningServers.push(server)

    const nativeResponse = await jsonRequest(server, "/v1/native-mcps")
    expect(nativeResponse.status).toBe(200)
    expect(nativeResponse.body).toEqual(nativeMcpScan)

    const importResponse = await jsonRequest(server, "/v1/native-mcps/import", {
      body: JSON.stringify({ identities: ["docs-mcp"] }),
      method: "POST"
    })
    expect(importResponse.status).toBe(200)
    expect(importResponse.body).toEqual({
      outcomes: [{ identity: "docs-mcp", status: "imported", warnings: [] }],
      scan: nativeMcpScan
    })

    const skillsResponse = await jsonRequest(server, "/v1/skills")
    expect(skillsResponse.status).toBe(200)
    expect(skillsResponse.body).toEqual(skillsScan)

    // Unknown methods and subpaths fall through to 404.
    expect((await jsonRequest(server, "/v1/native-mcps", { method: "POST" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/native-mcps/unknown")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills/unknown")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills/unknown", { method: "PATCH" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills", { method: "PATCH" })).status).toBe(404)
  })

  it("routes native MCP destructive operations to the manager", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<unknown[]> = []
    const server = await startWithApp({ ...services, nativeMcp: nativeMcpStub(calls) })
    runningServers.push(server)

    const removeResponse = await jsonRequest(server, "/v1/native-mcps/remove", {
      body: JSON.stringify({ harnessId: "claude-code", serverName: "docs" }),
      method: "POST"
    })
    expect(removeResponse.status).toBe(200)
    expect(removeResponse.body).toEqual({ removal: nativeMcpRemoval, scan: nativeMcpScan })

    const removalsResponse = await jsonRequest(server, "/v1/native-mcps/removals")
    expect(removalsResponse.status).toBe(200)
    expect(removalsResponse.body).toEqual([nativeMcpRemoval])

    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/restore", {
          method: "POST"
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/unknown", {
          method: "POST"
        })
      ).status
    ).toBe(404)

    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/set-enabled", {
          body: JSON.stringify({ enabled: false, harnessId: "opencode", serverName: "local" }),
          method: "POST"
        })
      ).status
    ).toBe(200)

    expect(calls).toEqual([
      ["removeServer", "claude-code", "docs"],
      ["restoreRemoval", "removal-1"],
      ["setNativeEnabled", "opencode", "local", false]
    ])
  })

  it("maps NativeMcpError codes onto HTTP statuses", async () => {
    const { services } = await makeServices("server-a")
    const failing = {
      ...nativeMcpStub([]),
      removeServer: async () => {
        throw new NativeMcpError("can't edit safely", "unsupported")
      },
      restoreRemoval: async () => {
        throw new NativeMcpError("name in use", "conflict")
      },
      setNativeEnabled: async () => {
        throw new NativeMcpError("no such server", "notFound")
      }
    }
    const server = await startWithApp({ ...services, nativeMcp: failing })
    runningServers.push(server)

    const unsupported = await jsonRequest(server, "/v1/native-mcps/remove", {
      body: JSON.stringify({ harnessId: "goose", serverName: "docs" }),
      method: "POST"
    })
    expect(unsupported.status).toBe(422)
    expect(unsupported.body).toEqual({ code: "unsupported", error: "can't edit safely" })
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/restore", {
          method: "POST"
        })
      ).status
    ).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/set-enabled", {
          body: JSON.stringify({ enabled: true, harnessId: "opencode", serverName: "ghost" }),
          method: "POST"
        })
      ).status
    ).toBe(404)
  })

  it("returns 501 when the host has no native MCP or skills managers", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/native-mcps")).status).toBe(501)
    expect((await jsonRequest(server, "/v1/skills")).status).toBe(501)
  })
})
