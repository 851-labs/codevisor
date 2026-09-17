import { mkdtemp, rm, writeFile } from "node:fs/promises"
import * as fs from "node:fs/promises"
import { IncomingMessage, ServerResponse } from "node:http"
import { Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { SharedCredentialError, type SharedTokenBundle } from "@codevisor/harness-manager"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { fleet } from "./shared-accounts-test-support.js"
import { makeSharedProviderRuntime, readProviderDocument } from "./shared-provider-runtime.js"

vi.mock("node:fs/promises", { spy: true })

const capability = "a".repeat(43)
const token: SharedTokenBundle = {
  harnessId: "pi",
  providerId: "anthropic",
  subject: "user",
  accessToken: "access",
  refreshToken: "never-return-this",
  expiresAt: 9_000_000_000_000,
  ownership: "managed",
  credential: { type: "oauth", refresh: "never-return-this", projectId: "project" }
}
const fixture = () => {
  const row = { harnessId: "pi", credential: { id: "reference", key: "key" } }
  const get = vi.fn(async () => row as typeof row | undefined)
  const read = vi.fn(async () => token)
  const runtime = makeSharedProviderRuntime({
    dataDir: "unused",
    baseUrl: "http://127.0.0.1:1",
    store: {
      localEntries: async () => [
        { key: "cap:malformed", value: null },
        { key: "cap:string", value: "invalid" },
        { key: "cap:key", value: { capability, slot: "provider:slot", credentialId: "reference" } }
      ],
      get
    } as unknown as Parameters<typeof makeSharedProviderRuntime>[0]["store"],
    vault: { token: read } as unknown as Parameters<typeof makeSharedProviderRuntime>[0]["vault"]
  })
  const send = async (
    options: {
      body?: string
      bearer?: string
      origin?: string
      address?: string | null
      method?: string
    } = {}
  ) => {
    const request = new IncomingMessage(new Socket())
    Object.defineProperty(request.socket, "remoteAddress", {
      value: options.address === null ? undefined : (options.address ?? "127.0.0.1")
    })
    request.method = options.method ?? "POST"
    request.headers = {
      authorization: options.bearer ?? `Bearer ${capability}`,
      ...(options.origin ? { origin: options.origin } : {})
    }
    request.push(Buffer.from(options.body ?? "{}"))
    request.push(null)
    const response = new ServerResponse(request)
    let body = ""
    response.end = ((value?: string) => {
      body = value ?? ""
      return response
    }) as typeof response.end
    await runtime.handle(request, response)
    return { status: response.statusCode, body, cache: response.getHeader("Cache-Control") }
  }
  return { get, read, send, row }
}

describe("provider token broker", () => {
  it("returns only access credentials with the same opaque native refresh handle", async () => {
    const f = fixture()
    const response = await f.send({ body: JSON.stringify({ rejectedAccessToken: "old" }) })
    expect(response.status).toBe(200)
    expect(response.cache).toBe("no-store")
    expect(JSON.parse(response.body)).toMatchObject({
      credential: { access: "access", refresh: `codevisor:${capability}`, projectId: "project" }
    })
    expect(response.body).not.toContain("never-return-this")
    expect(f.read).toHaveBeenCalledWith(f.row.credential, "old")
    f.read.mockResolvedValueOnce({ ...token, idToken: "identity" })
    expect(JSON.parse((await f.send()).body).idToken).toBe("identity")
  })
  it("rejects browser requests, remote peers, invalid capabilities and unsupported methods before reading credentials", async () => {
    const f = fixture()
    for (const options of [
      { origin: "https://example.test" },
      { address: "192.0.2.1" },
      { address: null }
    ])
      expect((await f.send(options)).status).toBe(403)
    expect((await f.send({ method: "GET" })).status).toBe(405)
    for (const bearer of ["", "Bearer malformed", `Bearer ${"b".repeat(43)}`])
      expect((await f.send({ bearer })).status).toBe(401)
    expect(f.read).not.toHaveBeenCalled()
    expect((await f.send({ address: "::1" })).status).toBe(200)
    expect((await f.send({ address: "::ffff:127.0.0.1" })).status).toBe(200)
  })
  it("revokes old capabilities when a provider is removed or its selected grant changes", async () => {
    const f = fixture()
    f.get.mockResolvedValueOnce(undefined)
    expect((await f.send()).status).toBe(401)
    f.get.mockResolvedValueOnce({
      ...f.row,
      credential: { ...f.row.credential, id: "replacement" }
    })
    expect((await f.send()).status).toBe(401)
    expect(f.read).not.toHaveBeenCalled()
  })
  it("bounds request size and validates request bodies without exposing tokens in errors", async () => {
    const f = fixture()
    for (const body of ["", "{", "null", "[]", "123", JSON.stringify({ rejectedAccessToken: 123 })])
      expect((await f.send({ body })).status).toBe(400)
    expect((await f.send({ body: "x".repeat(16_385) })).status).toBe(413)
    expect(f.read).not.toHaveBeenCalled()
    for (const error of [
      new Error("secret provider body"),
      new SharedCredentialError("offline"),
      new SharedCredentialError("revoked")
    ]) {
      f.read.mockRejectedValueOnce(error)
      const response = await f.send()
      expect(response.status).toBe(
        error instanceof SharedCredentialError && error.reason === "revoked" ? 401 : 503
      )
      expect(response.body).not.toContain("secret provider body")
    }
  })
  it("honors Grok's expired-token signal without giving Grok a refresh token", async () => {
    const f = fixture()
    f.row.harnessId = "grok-build"
    f.read
      .mockResolvedValueOnce({ ...token, harnessId: "grok-build" })
      .mockResolvedValueOnce({ ...token, harnessId: "grok-build", accessToken: "fresh" })
    const response = await f.send({ body: JSON.stringify({ force: true }) })
    const value = JSON.parse(response.body)
    expect(value).toMatchObject({ access_token: "fresh", issuer: "https://auth.x.ai" })
    expect(value.refresh_token).toBeUndefined()
    expect(f.read).toHaveBeenNthCalledWith(2, f.row.credential, "access")
    f.row.harnessId = "pi"
    await f.send({ body: JSON.stringify({ force: true }) })
    expect(f.read).toHaveBeenCalledTimes(3)
  })
})

it("fails safely when a required native resource cannot be linked", async () => {
  const host = await fleet().machine("link-failure")
  await host.shared.providers.capture("pi", "default", "anthropic", {
    type: "oauth",
    access: "a",
    refresh: "r",
    expires: 9_000_000_000_000
  })
  const link = vi
    .spyOn(fs, "symlink")
    .mockRejectedValueOnce(Object.assign(new Error("Denied"), { code: "EACCES" }))
  try {
    const contexts = await Promise.allSettled(
      Array.from({ length: 3 }, () =>
        host.shared.providers.context({ id: "pi-default", harnessId: "pi" } as never, {
          id: "pi-default",
          profileKind: "default"
        })
      )
    )
    expect(contexts[0]).toMatchObject({
      status: "rejected",
      reason: expect.objectContaining({ message: "Denied" })
    })
    expect(contexts.slice(1).map((result) => result.status)).toEqual(["fulfilled", "fulfilled"])
  } finally {
    link.mockRestore()
  }
})

it("distinguishes a missing credential file from a malformed or unreadable file", async () => {
  const root = await mkdtemp(join(tmpdir(), "provider-document-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  const path = join(root, "auth.json")
  expect(await readProviderDocument(path)).toEqual({})
  for (const content of ["null", "[]", '"string"', "{"]) {
    await writeFile(path, content)
    await expect(readProviderDocument(path)).rejects.toThrow("could not be read")
  }
  await expect(readProviderDocument(root)).rejects.toThrow("could not be read")
})
