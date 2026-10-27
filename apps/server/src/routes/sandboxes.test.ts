import { randomBytes } from "node:crypto"

import { afterEach, describe, expect, it, vi } from "vitest"

import { makeSandboxCredentialStore } from "../infra/sandbox-credentials.js"
import { sandboxHarness } from "../infra/sandbox-test-support.js"
import { run } from "../server-context.js"
import { jsonRequest, startWithApp } from "../test-support.js"

const secretValue = "sk-e2b-very-secret-value-0123456789"

const startSandboxServer = async () => {
  const harness = await sandboxHarness()
  const key = randomBytes(32)
  const credentials = makeSandboxCredentialStore(harness.services.db, () => key)
  const server = await startWithApp({
    ...harness.services,
    sandboxes: { machines: harness.machines, credentials, records: harness.records }
  })
  return { harness, credentials, server }
}

const put = (body: unknown): RequestInit => ({ method: "PUT", body: JSON.stringify(body) })

afterEach(() => {
  vi.restoreAllMocks()
})

describe("sandbox provider credentials", () => {
  it("are write-only: saved keys never come back from any endpoint, log or stored value", async () => {
    const logged: string[] = []
    for (const level of ["log", "error", "warn", "info"] as const) {
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
        logged.push(args.map(String).join(" "))
      })
    }
    const { harness, credentials, server } = await startSandboxServer()

    const saved = await jsonRequest(
      server,
      "/v1/sandbox-providers/e2b/credentials",
      put({ values: { apiKey: ` ${secretValue} ` } })
    )
    const providers = await jsonRequest(server, "/v1/sandbox-providers")
    const machines = await jsonRequest(server, "/v1/sandboxes")
    const stored = await run(
      harness.services.db.getMachineSetting("ephemeral-provider-credentials:e2b")
    )

    expect(saved.status).toBe(204)
    expect(providers.body).toMatchObject({
      providers: [
        { id: "e2b", displayName: "E2B", configured: true, credentialKeys: ["apiKey"] },
        { id: "modal", configured: false, credentialKeys: ["tokenId", "tokenSecret"] },
        { id: "tart", configured: false, credentialKeys: [] }
      ]
    })
    for (const seen of [providers.body, machines.body, stored, logged]) {
      expect(JSON.stringify(seen)).not.toContain(secretValue)
    }
    expect(await credentials.read("e2b")).toEqual({ apiKey: secretValue })
    expect(await credentials.read("tart")).toEqual({})
    expect([
      await credentials.isConfigured("e2b"),
      await credentials.isConfigured("modal")
    ]).toEqual([true, false])
  })

  it("rejects incomplete keys, keys for Tart and unknown providers, and can be cleared", async () => {
    const { server } = await startSandboxServer()
    const path = "/v1/sandbox-providers/modal/credentials"

    const incomplete = await jsonRequest(
      server,
      path,
      put({ values: { tokenId: "id", tokenSecret: " " } })
    )
    const absent = await jsonRequest(
      server,
      "/v1/sandbox-providers/e2b/credentials",
      put({ values: {} })
    )
    const tart = await jsonRequest(
      server,
      "/v1/sandbox-providers/tart/credentials",
      put({ values: {} })
    )
    const unknown = await jsonRequest(
      server,
      "/v1/sandbox-providers/aws/credentials",
      put({ values: {} })
    )
    await jsonRequest(server, path, put({ values: { tokenId: "id", tokenSecret: "s" } }))
    const cleared = await jsonRequest(server, path, { method: "DELETE" })
    const providers = await jsonRequest(server, "/v1/sandbox-providers")

    expect(incomplete).toMatchObject({ status: 400, body: { error: "Missing tokenSecret" } })
    expect(absent).toMatchObject({ status: 400, body: { error: "Missing apiKey" } })
    expect(tart.status).toBe(400)
    expect(unknown.status).toBe(404)
    expect(cleared.status).toBe(204)
    expect(providers.body).toMatchObject({
      providers: [{}, { id: "modal", configured: false }, {}]
    })
  })
})

describe("sandbox routes", () => {
  it("creates, lists and destroys sandboxes", async () => {
    const { harness, server } = await startSandboxServer()

    const created = await jsonRequest(server, "/v1/sandboxes", {
      method: "POST",
      body: JSON.stringify({ provider: "e2b", projectId: "project-1", name: "box" })
    })
    await harness.machines.settled()
    const listed = await jsonRequest(server, "/v1/sandboxes")
    const destroyed = await jsonRequest(server, "/v1/sandboxes/id-1", { method: "DELETE" })

    expect(created).toMatchObject({
      status: 202,
      body: { id: "id-1", state: "creating" }
    })
    expect(listed.body).toMatchObject([{ id: "id-1", state: "ready" }])
    expect(destroyed).toEqual({ status: 200, body: { destroyed: "id-1" } })
    expect(harness.provider.machines.size).toBe(0)
  })

  it("hands a machine started before the first send to the chat's workspace", async () => {
    const { harness, server } = await startSandboxServer()
    await jsonRequest(server, "/v1/sandboxes", {
      method: "POST",
      body: JSON.stringify({ provider: "e2b", projectId: "project-1", defersWorkspace: true })
    })
    await harness.machines.settled()

    const claimed = await jsonRequest(server, "/v1/sandboxes/id-1/workspace", {
      method: "POST",
      body: JSON.stringify({ workspaceId: "workspace-1" })
    })

    expect(claimed).toMatchObject({ status: 200, body: { id: "id-1", workspaceId: "workspace-1" } })
  })

  it("stores per-project provider options after checking them against each provider's schema", async () => {
    const { server } = await startSandboxServer()
    const path = "/v1/projects/project-1/sandbox-options"

    const empty = await jsonRequest(server, path)
    const saved = await jsonRequest(server, path, put({ e2b: { template: "codevisor-4gb" } }))
    const invalid = await jsonRequest(server, path, put({ modal: { cpu: "lots" } }))
    const read = await jsonRequest(server, path)

    expect(empty.body).toEqual({ projectId: "project-1", options: {} })
    expect(saved.status).toBe(200)
    expect(invalid.status).toBe(400)
    expect(read.body).toEqual({
      projectId: "project-1",
      options: { e2b: { template: "codevisor-4gb" } }
    })
  })

  it("reports the defaults each provider fills in", async () => {
    const { server } = await startSandboxServer()

    const providers = await jsonRequest(server, "/v1/sandbox-providers")

    expect(providers.body).toMatchObject({
      providers: [
        { defaults: { template: "base", timeoutMinutes: 60 } },
        {
          defaults: { image: "debian:bookworm-slim", cpu: 2, memoryMiB: 4096, timeoutMinutes: 1440 }
        },
        {
          defaults: {
            baseImage: "ghcr.io/cirruslabs/macos-tahoe-base:latest",
            cpu: 4,
            memoryGiB: 8
          }
        }
      ]
    })
  })

  it("leaves other methods on sandbox paths to the rest of the router", async () => {
    const { server } = await startSandboxServer()

    expect((await jsonRequest(server, "/v1/sandboxes/id-1", { method: "PATCH" })).status).toBe(404)
  })

  it("answers 501 when the server has no sandbox support", async () => {
    const { harness } = await startSandboxServer()
    const bare = await startWithApp(harness.services)

    expect((await jsonRequest(bare, "/v1/sandboxes")).status).toBe(501)
    expect((await jsonRequest(bare, "/v1/projects/p/sandbox-options")).status).toBe(501)
  })
})
