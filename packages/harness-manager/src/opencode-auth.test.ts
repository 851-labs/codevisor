import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import { makeOpenCodeAuthManager, openCodeAuthPath } from "./opencode-auth.js"

const normalizationFixture = {
  providers: {
    all: [
      { id: "missing", name: "C Missing" },
      { id: "empty", name: "B Empty" },
      { id: "normalized", name: "A Normalized" }
    ]
  },
  methods: {
    normalized: [
      { type: "invalid" },
      {
        type: "oauth",
        prompts: [
          { type: "invalid", key: "bad", message: "Bad" },
          { type: "text", message: "Missing key" },
          { type: "text", key: "missing-message" },
          { type: "text", key: "plain", message: "Plain" },
          {
            type: "text",
            key: "eq",
            message: "Equal",
            placeholder: "",
            when: { key: "plan", op: "eq", value: "plus" }
          },
          {
            type: "select",
            key: "neq",
            message: "Different",
            options: [
              { label: "No value" },
              { value: "no-label" },
              { value: "one", label: "One" },
              { value: "two", label: "Two", hint: "Second" }
            ],
            when: { key: "plan", op: "neq", value: "free" }
          },
          {
            type: "text",
            key: "missing-when-key",
            message: "No condition key",
            when: { op: "eq", value: "x" }
          },
          {
            type: "text",
            key: "bad-when-op",
            message: "Bad condition op",
            when: { key: "plan", op: "invalid", value: "x" }
          },
          {
            type: "text",
            key: "missing-when-value",
            message: "No condition value",
            when: { key: "plan", op: "eq" }
          },
          { type: "select", key: "absent-options", message: "Absent options" },
          { type: "select", key: "empty-options", message: "Empty options", options: [] }
        ]
      },
      { type: "api", label: "Ignored label" },
      { type: "oauth", label: "Named OAuth" }
    ],
    empty: []
  }
} as const

const normalizedProviders = [
  {
    id: "normalized",
    name: "A Normalized",
    methods: [
      {
        id: "1",
        type: "oauth",
        label: "Provider account",
        prompts: [
          { type: "text", key: "plain", message: "Plain", options: [] },
          {
            type: "text",
            key: "eq",
            message: "Equal",
            options: [],
            placeholder: "",
            when: { key: "plan", op: "eq", value: "plus" }
          },
          {
            type: "select",
            key: "neq",
            message: "Different",
            options: [
              { value: "one", label: "One" },
              { value: "two", label: "Two", hint: "Second" }
            ],
            when: { key: "plan", op: "neq", value: "free" }
          },
          { type: "text", key: "missing-when-key", message: "No condition key", options: [] },
          { type: "text", key: "bad-when-op", message: "Bad condition op", options: [] },
          { type: "text", key: "missing-when-value", message: "No condition value", options: [] },
          { type: "select", key: "absent-options", message: "Absent options", options: [] },
          { type: "select", key: "empty-options", message: "Empty options", options: [] }
        ]
      },
      { id: "2", type: "api", label: "API key", prompts: [] },
      { id: "3", type: "oauth", label: "Named OAuth", prompts: [] }
    ]
  },
  {
    id: "empty",
    name: "B Empty",
    methods: [{ id: "0", type: "api", label: "API key", prompts: [] }]
  },
  {
    id: "missing",
    name: "C Missing",
    methods: [{ id: "0", type: "api", label: "API key", prompts: [] }]
  }
] as const

const fakeOpenCode = (directory: string, fixturePath?: string): string => {
  const path = join(directory, "opencode")
  writeFileSync(
    path,
    `#!/usr/bin/env node
const http = require("node:http")
const fs = require("node:fs")
const path = require("node:path")
const authPath = path.join(process.env.XDG_DATA_HOME, "opencode", "auth.json")
if (process.env.OPENCODE_DB !== ":memory:") throw new Error("auth server must use an isolated database")
fs.mkdirSync(path.dirname(authPath), { recursive: true })
const serverLock = path.join(path.dirname(authPath), "auth-server.lock")
try { fs.writeFileSync(serverLock, String(process.pid), { flag: "wx" }) } catch { console.error("overlapping auth servers"); process.exit(73) }
let cleaned = false
const cleanup = () => { if (cleaned) return; cleaned = true; try { fs.unlinkSync(serverLock) } catch {} }
const read = () => { try { return JSON.parse(fs.readFileSync(authPath, "utf8")) } catch { return {} } }
const write = (value) => { fs.mkdirSync(path.dirname(authPath), { recursive: true }); fs.writeFileSync(authPath, JSON.stringify(value), { mode: 0o600 }) }
const json = (res, status, value) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(value)) }
const body = (req) => new Promise((resolve) => { let value = ""; req.on("data", (x) => value += x); req.on("end", () => resolve(value ? JSON.parse(value) : {})) })
const expected = "Basic " + Buffer.from("opencode:" + process.env.OPENCODE_SERVER_PASSWORD).toString("base64")
const fixturePath = ${JSON.stringify(fixturePath ?? null)}
const fixture = fixturePath === null ? undefined : JSON.parse(fs.readFileSync(fixturePath, "utf8"))
const server = http.createServer(async (req, res) => {
  if (req.headers.authorization !== expected) return json(res, 401, { message: "unauthorized" })
  const url = new URL(req.url, "http://localhost")
  if (fixture !== undefined && req.method === "GET" && url.pathname === "/provider") return json(res, 200, fixture.providers)
  if (fixture !== undefined && req.method === "GET" && url.pathname === "/provider/auth") return json(res, 200, fixture.methods)
  if (req.method === "GET" && url.pathname === "/provider") return json(res, 200, { all: [{ id: "openai", name: "OpenAI" }], connected: [], default: {} })
  if (req.method === "GET" && url.pathname === "/provider/auth") return json(res, 200, { openai: [{ type: "oauth", label: "ChatGPT", prompts: [{ type: "select", key: "plan", message: "Plan", options: [{ value: "plus", label: "Plus" }] }] }, { type: "api", label: "API key" }] })
  if (req.method === "POST" && url.pathname === "/provider/openai/oauth/authorize") return json(res, 200, { url: "https://example.test/login", method: "code", instructions: "Sign in" })
  if (req.method === "POST" && url.pathname === "/provider/openai/oauth/callback") { const value = await body(req); if (value.code !== "right-code") return json(res, 400, { data: { message: "bad code" } }); write({ ...read(), openai: { type: "oauth", refresh: "r", access: "a", expires: 1 } }); return json(res, 200, true) }
  if (req.method === "PUT" && url.pathname === "/auth/openai") { const value = await body(req); write({ ...read(), openai: value }); return json(res, 200, true) }
  if (req.method === "DELETE" && url.pathname === "/auth/openai") { const value = read(); delete value.openai; write(value); return json(res, 200, true) }
  return json(res, 404, { message: "not found" })
})
process.on("SIGTERM", () => server.close(() => { cleanup(); process.exit(0) }))
process.on("exit", cleanup)
server.listen(0, "127.0.0.1", () => { const address = server.address(); console.log("opencode server listening on http://127.0.0.1:" + address.port) })
`,
    { mode: 0o755 }
  )
  chmodSync(path, 0o755)
  return path
}

describe("OpenCode provider authentication", () => {
  it("normalizes upstream provider methods and prompts without inventing missing fields", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-opencode-methods-"))
    onTestFinished(() => rmSync(root, { recursive: true, force: true }))
    const fixturePath = join(root, "descriptors.json")
    writeFileSync(fixturePath, JSON.stringify(normalizationFixture))
    const command = fakeOpenCode(root, fixturePath)
    const data = join(root, "data")
    const manager = makeOpenCodeAuthManager({
      profile: async () => ({
        command,
        cwd: root,
        env: { PATH: process.env.PATH, HOME: root, XDG_DATA_HOME: data },
        authPath: join(data, "opencode", "auth.json")
      })
    })
    expect(await manager.providers("normalization-account")).toStrictEqual(normalizedProviders)
  })

  it("captures isolated OAuth before completing and releases the flow after capture failure", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-opencode-managed-"))
    onTestFinished(() => rmSync(root, { recursive: true, force: true }))
    const command = fakeOpenCode(root)
    const profile = (name: string) => ({
      command,
      cwd: root,
      env: { PATH: process.env.PATH, HOME: root, XDG_DATA_HOME: join(root, name) },
      authPath: join(root, name, "opencode", "auth.json")
    })
    const captureOAuth = vi.fn(async (_account: string, _provider: string, path: string) => {
      expect(JSON.parse(readFileSync(path, "utf8")).openai.refresh).toBe("r")
    })
    const savedApiKey = vi.fn(async () => {})
    const manager = makeOpenCodeAuthManager({
      profile: async () => profile("native"),
      loginProfile: async () => profile("isolated"),
      captureOAuth,
      savedApiKey
    })
    const first = await manager.beginLogin("account", "openai", "0", undefined, undefined, true)
    expect((await manager.answer(first.id, "right-code")).state).toBe("complete")
    expect(captureOAuth).toHaveBeenCalledWith(
      "account",
      "openai",
      profile("isolated").authPath,
      true
    )
    expect(existsSync(profile("native").authPath)).toBe(false)
    captureOAuth.mockRejectedValueOnce(new Error("Unable to save account"))
    const failed = await manager.beginLogin("account", "openai", "0")
    expect(await manager.answer(failed.id, "right-code")).toMatchObject({
      state: "error",
      error: "Unable to save account"
    })
    const api = await manager.beginLogin("account", "openai", "1", undefined, "fixture-key")
    expect(api.state).toBe("complete")
    expect(savedApiKey).toHaveBeenCalledWith("account", "openai", false)
    expect(captureOAuth).toHaveBeenCalledTimes(2)
    expect((await manager.providers("account"))[0]?.credentialType).toBe("api")
  })
  it("uses the profile XDG data directory", () => {
    expect(openCodeAuthPath({ HOME: "/home/test" })).toBe(
      "/home/test/.local/share/opencode/auth.json"
    )
    expect(openCodeAuthPath({ HOME: "/home/test", XDG_DATA_HOME: "/profiles/data" })).toBe(
      "/profiles/data/opencode/auth.json"
    )
  })

  it("lists, adds, replaces, and removes profile-scoped credentials", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-opencode-auth-"))
    onTestFinished(() => rmSync(root, { recursive: true, force: true }))
    const data = join(root, "data")
    mkdirSync(data, { recursive: true })
    const command = fakeOpenCode(root)
    const manager = makeOpenCodeAuthManager({
      profile: async () => ({
        command,
        cwd: root,
        env: { ...process.env, HOME: root, XDG_DATA_HOME: data },
        authPath: join(data, "opencode", "auth.json")
      })
    })

    expect(await manager.providers("account-1")).toEqual([
      expect.objectContaining({
        id: "openai",
        methods: [
          expect.objectContaining({ id: "0", type: "oauth" }),
          expect.objectContaining({ id: "1", type: "api" })
        ]
      })
    ])

    const api = await manager.beginLogin(
      "account-1",
      "openai",
      "1",
      { organization: "personal" },
      "sk-secret"
    )
    expect(api.state).toBe("complete")
    expect((await manager.providers("account-1"))[0]?.credentialType).toBe("api")

    await manager.logout("account-1", "openai")
    expect((await manager.providers("account-1"))[0]?.credentialType).toBeUndefined()

    const oauth = await manager.beginLogin("account-1", "openai", "0", { plan: "plus" })
    expect(oauth).toMatchObject({
      state: "waiting",
      authorization: { method: "code", url: "https://example.test/login" }
    })
    expect((await manager.answer(oauth.id, "right-code")).state).toBe("complete")
    expect((await manager.providers("account-1"))[0]?.credentialType).toBe("oauth")
  })

  it("serializes auth servers that belong to the same profile", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-opencode-auth-lock-"))
    onTestFinished(() => rmSync(root, { recursive: true, force: true }))
    const data = join(root, "data")
    mkdirSync(data, { recursive: true })
    const manager = makeOpenCodeAuthManager({
      profile: async () => ({
        command: fakeOpenCode(root),
        cwd: root,
        env: { ...process.env, HOME: root, XDG_DATA_HOME: data },
        authPath: join(data, "opencode", "auth.json")
      })
    })

    const results = await Promise.all([
      manager.providers("account-1"),
      manager.providers("account-1"),
      manager.providers("account-1")
    ])
    expect(results.every((providers) => providers[0]?.id === "openai")).toBe(true)
  })
})
