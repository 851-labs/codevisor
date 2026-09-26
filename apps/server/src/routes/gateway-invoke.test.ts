import { CodeExecutionToolError } from "@codevisor/automation"
import type { McpManager } from "@codevisor/mcp"
import { describe, expect, it } from "vitest"

import type { MachineLink } from "../infra/machine-link.js"
import type { CodevisorServerServices } from "../server-context.js"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"

const origin = { machineId: "machine-studio", machineName: "Studio", sessionId: "s-1" }

type RemoteCall = McpManager["invokeRemoteGatewayCall"]

/// A real server whose gateway's remote-call entry point is scripted.
const serve = async (options: {
  machines?: MachineLink
  remote?: RemoteCall
  withoutGateway?: boolean
}) => {
  const { services } = await makeServices("server-machines")
  const overrides: Partial<CodevisorServerServices> = {
    ...(options.machines === undefined ? {} : { machines: options.machines }),
    ...(options.remote === undefined
      ? {}
      : { mcp: { ...services.mcp, invokeRemoteGatewayCall: options.remote } })
  }
  const { mcp: _mcp, ...withoutMcp } = services
  const server = await run(
    startCodevisorServer(
      { ...(options.withoutGateway === true ? withoutMcp : services), ...overrides },
      defaultServerConfig({ bootId: "test-boot", id: "server-machines", port: 0 })
    )
  )
  runningServers.push(server)
  return server
}

const invoke = (server: Awaited<ReturnType<typeof serve>>, body: unknown) =>
  jsonRequest(server, "/v1/gateway/invoke", { method: "POST", body: JSON.stringify(body) })

describe("machines routes", () => {
  it("lists the account's machines", async () => {
    const machines = [{ id: "machine-a", name: "A", online: true, isCurrent: true }]
    const link: MachineLink = { list: async () => machines, invoke: async () => undefined }
    const server = await serve({ machines: link })
    expect(await jsonRequest(server, "/v1/machines")).toEqual({ status: 200, body: { machines } })

    // Other methods fall through to the rest of the router.
    expect((await jsonRequest(server, "/v1/machines", { method: "POST" })).status).toBe(404)
    const bare = await serve({})
    expect((await jsonRequest(bare, "/v1/machines")).status).toBe(501)
  })

  it("runs a remote gateway call for the calling machine", async () => {
    const calls: unknown[] = []
    const server = await serve({
      remote: async (callOrigin, path, args) => {
        calls.push({ callOrigin, path, args })
        return path === "none" ? undefined : { issues: 3 }
      }
    })
    expect(
      await invoke(server, { path: "linear.list_issues", args: { team: "x" }, origin })
    ).toEqual({ status: 200, body: { result: { issues: 3 } } })
    expect(calls).toEqual([{ callOrigin: origin, path: "linear.list_issues", args: { team: "x" } }])
    // An undefined result still answers with a `result` key.
    const fromApp = { machineId: "machine-b", machineName: "B", sessionTitle: "T", clientId: "c" }
    expect((await invoke(server, { path: "none", origin: fromApp })).body).toEqual({ result: null })
    expect(calls.at(-1)).toEqual({ callOrigin: fromApp, path: "none", args: undefined })
  })

  it("reports tool errors with their code and details, and other failures as 500", async () => {
    const failures: unknown[] = [
      new CodeExecutionToolError("Laptop is offline", {
        code: "machine_unavailable",
        details: { machineId: "machine-laptop", phase: "before-send" }
      }),
      new Error("gateway exploded"),
      "bare failure"
    ]
    const server = await serve({ remote: async () => Promise.reject(failures.shift()) })
    expect(await invoke(server, { path: "x", origin })).toEqual({
      status: 422,
      body: {
        error: {
          message: "Laptop is offline",
          code: "machine_unavailable",
          details: { machineId: "machine-laptop", phase: "before-send" }
        }
      }
    })
    expect(await invoke(server, { path: "x", origin })).toEqual({
      status: 500,
      body: { error: { message: "gateway exploded" } }
    })
    expect(await invoke(server, { path: "x", origin })).toEqual({
      status: 500,
      body: { error: { message: "bare failure" } }
    })
  })

  it.each([
    ["a missing path", { origin }],
    ["a missing origin", { path: "x" }],
    ["an origin without a machine id", { path: "x", origin: { machineName: "A" } }],
    ["a non-string session id", { path: "x", origin: { ...origin, sessionId: 4 } }],
    ["a non-object body", [1]]
  ])("rejects %s", async (_label, body) => {
    const server = await serve({ remote: async () => "never" })
    const answer = await invoke(server, body)
    expect(answer.status).toBe(400)
    expect(answer.body).toMatchObject({ error: { message: expect.any(String) } })
  })

  it("answers 400 for a body that is not JSON and 501 without a gateway", async () => {
    const server = await serve({ remote: async () => "never" })
    const response = await fetch(`${server.url}/v1/gateway/invoke`, {
      method: "POST",
      body: "{"
    })
    expect(response.status).toBe(400)
    const bare = await serve({ withoutGateway: true })
    expect((await invoke(bare, { path: "x", origin })).status).toBe(501)
  })

  it("cancels the call when the calling machine hangs up", async () => {
    let received!: AbortSignal
    let started!: () => void
    const running = new Promise<void>((resolve) => {
      started = resolve
    })
    const aborted = new Promise<unknown>((resolve) => {
      void running.then(() => received.addEventListener("abort", () => resolve(received.reason)))
    })
    const server = await serve({
      remote: (_origin, _path, _args, signal) => {
        received = signal!
        started()
        return new Promise(() => undefined)
      }
    })
    const caller = new AbortController()
    const request = fetch(`${server.url}/v1/gateway/invoke`, {
      method: "POST",
      body: JSON.stringify({ path: "slow", origin }),
      signal: caller.signal
    }).catch(() => undefined)
    await running
    caller.abort()
    await request
    expect(await aborted).toBeInstanceOf(Error)
  })
})
