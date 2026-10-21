import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeOpenCodeServerPool } from "./pool.js"
import { makeOpenCodeServerSessions, type OpenCodeServerLaunch } from "./server-provider.js"
import type { OpenCodeServerOptions } from "./server.js"
import { event, makeFakeServer, makeSink, type RecordedRequest } from "./test-support.js"

const catalog: Record<string, unknown> = {
  "/api/plugin": { data: [{ id: "core" }] },
  "/api/model": { data: [{ id: "m1", providerID: "p", name: "M1" }] },
  "/api/model/default": { data: { providerID: "p", id: "m1" } },
  "/api/agent": { data: [{ id: "build", name: "Build" }] },
  "/api/command": { data: [] },
  "/api/skill": { data: [] }
}

const setup = (respond: (request: RecordedRequest) => unknown = () => undefined) => {
  const fake = makeFakeServer((request) => catalog[request.path] ?? respond(request))
  const starts: Array<OpenCodeServerOptions> = []
  let scheduled: (() => Promise<void>) | undefined
  const pool = makeOpenCodeServerPool({
    schedule: (_ms, run) => {
      scheduled = run
      return () => {
        scheduled = undefined
      }
    }
  })
  const sessions = makeOpenCodeServerSessions({
    pool,
    start: async (options) => {
      starts.push(options)
      return fake.server
    },
    newMessageID: () => "msg_1",
    readable: async () => true,
    wait: async () => undefined
  })
  const sink = makeSink()
  const launch = (overrides: Partial<OpenCodeServerLaunch> = {}): OpenCodeServerLaunch => ({
    command: "/bin/opencode",
    cwd: "/work",
    env: { HOME: "/home/me", PWD: "/work" },
    harnessName: "OpenCode",
    emit: sink.emit,
    ...overrides
  })
  return { ...fake, sessions, starts, launch, sink, idle: () => scheduled?.() }
}

describe("OpenCode server sessions", () => {
  it("creates a session on a leased server, registers Codevisor's tools and shares the server", async () => {
    const s = setup((request) =>
      request.path === "/api/session" && request.method === "POST"
        ? { data: { id: "ses_1", agent: "plan", model: { providerID: "p", id: "m1" } } }
        : undefined
    )
    s.queue.push(event("server.connected", {}))
    const created = await s.sessions.create(
      s.launch({
        toolGateway: { name: "codevisor", url: "http://gw/mcp?gateway=1", bearerToken: "tok" }
      })
    )
    expect(created.metadata).toMatchObject({ sessionId: "ses_1", skills: { skills: [] } })
    expect(created.metadata.modes?.currentModeId).toBe("plan")
    expect(s.requests.some((request) => request.path === "/api/session/ses_1/model")).toBe(false)
    expect(s.starts).toEqual([
      { command: "/bin/opencode", env: { HOME: "/home/me", PWD: "/work" }, cwd: "/work" }
    ])
    expect(s.requests.find((request) => request.path === "/api/session")?.body).toEqual({
      location: { directory: "/work" }
    })
    expect(s.requests.find((request) => request.path.startsWith("/api/experimental/mcp/"))).toEqual(
      {
        path: "/api/experimental/mcp/codevisor",
        method: "PUT",
        location: "/work",
        body: {
          config: {
            type: "remote",
            url: "http://gw/mcp?gateway=1",
            headers: { Authorization: "Bearer tok" },
            oauth: false,
            codemode: false
          }
        }
      }
    )

    expect(
      await s.sessions.list(s.launch({ env: { HOME: "/home/me", PWD: "/elsewhere" } }))
    ).toEqual([])
    expect(s.starts).toHaveLength(2)
    await s.sessions.list(s.launch({ env: { HOME: "/home/me", PWD: "/third" } }))
    expect(s.starts).toHaveLength(2)
    await Effect.runPromise(created.handle.close)
    expect(s.subscriptions[0]?.aborted).toBe(true)
  })

  it("pins a new session to the model it advertises, but leaves loaded sessions alone", async () => {
    const s = setup((request) =>
      request.path === "/api/session" && request.method === "POST"
        ? { data: { id: "ses_new" } }
        : request.path === "/api/session/ses_old"
          ? { data: { id: "ses_old", location: { directory: "/work" } } }
          : undefined
    )
    s.queue.push(event("server.connected", {}))
    const created = await s.sessions.create(s.launch())
    expect(
      s.requests.find((request) => request.path === "/api/session/ses_new/model")?.body
    ).toEqual({
      model: { providerID: "p", id: "m1" }
    })
    expect(created.metadata.configOptions[0]).toMatchObject({ id: "model", currentValue: "p/m1" })
    await Effect.runPromise(created.handle.close)

    s.queue.push(event("server.connected", {}))
    const loaded = await s.sessions.load(s.launch(), "ses_old")
    expect(s.requests.some((request) => request.path === "/api/session/ses_old/model")).toBe(false)
    await Effect.runPromise(loaded.handle.close)
  })

  it("loads a session from its own directory and refuses one from another project", async () => {
    const s = setup((request) =>
      request.path === "/api/session/ses_2"
        ? { data: { id: "ses_2", location: { directory: "/work/" } } }
        : request.path === "/api/session/ses_3"
          ? { data: { id: "ses_3", location: { directory: "/other" } } }
          : undefined
    )
    s.queue.push(event("server.connected", {}))
    const loaded = await s.sessions.load(s.launch(), "ses_2")
    expect(loaded.metadata.sessionId).toBe("ses_2")
    await Effect.runPromise(loaded.handle.close)

    const other = setup((request) =>
      request.path === "/api/session/ses_3"
        ? { data: { id: "ses_3", location: { directory: "/other" } } }
        : undefined
    )
    other.queue.push(event("server.connected", {}))
    await expect(other.sessions.load(other.launch(), "ses_3")).rejects.toThrow(
      "OpenCode session ses_3 belongs to /other, not /work."
    )
    expect(other.queue.returned()).toBe(1)
    await other.idle()
    expect(other.stopped()).toBe(1)
  })

  it("gives up when the event stream does not open or the session has no id", async () => {
    const closed = setup()
    closed.queue.end()
    await expect(closed.sessions.create(closed.launch())).rejects.toThrow(
      "OpenCode's event stream did not connect."
    )
    const anonymous = setup(() => ({ data: {} }))
    anonymous.queue.push(event("server.connected", {}))
    await expect(anonymous.sessions.create(anonymous.launch())).rejects.toThrow(
      "OpenCode returned a session without an id."
    )
  })

  it("lists every page of sessions with their directories and update times", async () => {
    const s = setup((request) => {
      if (!request.path.startsWith("/api/session?")) return undefined
      const query = new URLSearchParams(request.path.slice(request.path.indexOf("?") + 1))
      expect(query.get("order")).toBe("desc")
      return query.get("cursor") === null
        ? {
            data: [
              { id: "ses_a", title: "First", location: { directory: "/a" }, time: { updated: 0 } },
              { id: "ses_broken" }
            ],
            cursor: { next: "page-2" }
          }
        : { data: [{ id: "ses_b", location: { directory: "/b" } }], cursor: { next: "page-2" } }
    })
    expect(await s.sessions.list(s.launch())).toEqual([
      { sessionId: "ses_a", cwd: "/a", title: "First", updatedAt: "1970-01-01T00:00:00.000Z" },
      { sessionId: "ses_b", cwd: "/b" }
    ])
  })
})
