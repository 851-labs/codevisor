import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { coordinateCredential, type CredentialRecord } from "@codevisor/api"
import { afterEach, expect, it, vi } from "vitest"

import { makeCredentialCoordinator } from "./credential-coordinator.js"

const dirs: string[] = []
afterEach(async () => {
  for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})
const fixture = async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "credential-coordinator-"))
  dirs.push(dataDir)
  const records = new Map<string, CredentialRecord>()
  let account = "user-one"
  let status = 200
  const requests: Array<{ action: string; expected?: string }> = []
  const request = vi.fn<typeof fetch>(async (url, init) => {
    const body = JSON.parse(String(init?.body))
    const expected = new Headers(init?.headers).get("x-codevisor-account") ?? undefined
    requests.push({ action: body.action, ...(expected ? { expected } : {}) })
    if (status !== 200) return new Response(null, { status })
    if (expected && expected !== account) return new Response(null, { status: 409 })
    const id = String(url).split("/").at(-1)!
    const next = coordinateCredential(records.get(id), body, "machine", 100)
    if (next.record) records.set(id, next.record)
    return Response.json(next.result, {
      headers: account ? { "x-codevisor-account": account } : {}
    })
  })
  const cloud = (
    value = { serverUrl: "https://cloud.test/", apiKey: "key", deviceId: "machine" }
  ) => writeFile(join(dataDir, "cloud.json"), JSON.stringify(value))
  return {
    dataDir,
    records,
    requests,
    request,
    cloud,
    coordinator: makeCredentialCoordinator({ dataDir, fetch: request }),
    account: (v: string) => {
      account = v
    },
    status: (v: number) => {
      status = v
    }
  }
}
const id = "credential-test-0001"
it("persists local grants and migrates their encrypted generation before using cloud authority", async () => {
  const f = await fixture()
  expect((await f.coordinator(id, { action: "read" })).status).toBe("missing")
  await f.coordinator(id, { action: "seed", sealed: "ciphertext" })
  expect(
    (await makeCredentialCoordinator({ dataDir: f.dataDir })(id, { action: "read" })).credential
      ?.sealed
  ).toBe("ciphertext")
  expect((await f.coordinator.cached(id))?.generation).toBe(1)
  await f.cloud()
  expect((await f.coordinator(id, { action: "read" })).credential?.sealed).toBe("ciphertext")
  expect(f.requests.map((x) => x.action)).toEqual(["read", "seed", "read"])
  expect((await f.coordinator.cached(id))?.sealed).toBe("ciphertext")
  await rm(join(f.dataDir, "cloud.json"))
  await expect(
    f.coordinator(id, { action: "acquire", generation: 1, operationId: "operation-test-0001" })
  ).rejects.toThrow("Connect to sync")
  expect(await f.coordinator.cached(id)).toBeUndefined()
  expect(f.records.get(id)?.operation).toBeUndefined()
})
it("binds cloud grants to the original account before mutation, including after an API key change", async () => {
  const f = await fixture()
  await f.cloud()
  await f.coordinator(id, { action: "seed", sealed: "ciphertext" })
  f.account("user-two")
  await f.cloud({ serverUrl: "https://cloud.test/", apiKey: "new-key", deviceId: "machine" })
  expect(await f.coordinator.cached(id)).toBeUndefined()
  await expect(f.coordinator(id, { action: "revoke" })).rejects.toThrow("Sign in")
  expect(f.records.get(id)?.revoked).toBe(false)
  await f.cloud({ serverUrl: "https://different.test", apiKey: "key", deviceId: "machine" })
  await expect(f.coordinator(id, { action: "read" })).rejects.toThrow("Sign in")
})
it("preserves revocation and refuses to migrate a refresh in progress", async () => {
  const f = await fixture()
  await f.coordinator(id, { action: "revoke" })
  await f.cloud()
  expect((await f.coordinator(id, { action: "read" })).status).toBe("revoked")
  await rm(join(f.dataDir, "cloud.json"))
  const pending = "credential-pending-0001"
  await f.coordinator(pending, { action: "seed", sealed: "ciphertext" })
  await f.coordinator(pending, {
    action: "acquire",
    generation: 1,
    operationId: "operation-test-0001"
  })
  await f.cloud()
  await expect(f.coordinator(pending, { action: "read" })).rejects.toThrow("refresh must finish")
  expect(f.records.has(pending)).toBe(false)
})
it("fails closed on malformed identity, storage, and network responses", async () => {
  const f = await fixture()
  await expect(f.coordinator("../bad", { action: "read" })).rejects.toThrow("Invalid credential")
  await writeFile(join(f.dataDir, "cloud.json"), "{")
  await expect(f.coordinator(id, { action: "read" })).rejects.toThrow()
  await f.cloud()
  f.account("")
  await expect(f.coordinator(id, { action: "read" })).rejects.toThrow("Sign in")
  f.account("user-one")
  f.status(503)
  await expect(f.coordinator(id, { action: "read" })).rejects.toThrow("unavailable")
  f.status(200)
  expect((await f.coordinator(id, { action: "read" })).status).toBe("missing")
  // A server that ignores the request's account binding is still rejected.
  const hostile = makeCredentialCoordinator({
    dataDir: f.dataDir,
    fetch: vi.fn<typeof fetch>(async () =>
      Response.json({ status: "missing" }, { headers: { "x-codevisor-account": "other" } })
    )
  })
  await expect(hostile(id, { action: "read" })).rejects.toThrow("Sign in")
  expect(
    JSON.parse(await readFile(join(f.dataDir, "shared-credentials", `${id}.json`), "utf8")).account
  ).toBe("user-one")
})

it("retains cloud authority when a deleted account returns an empty tombstone", async () => {
  const f = await fixture()
  await f.coordinator(id, { action: "seed", sealed: "ciphertext" })
  await f.cloud()
  const deleted = makeCredentialCoordinator({
    dataDir: f.dataDir,
    fetch: (async () =>
      Response.json(
        { status: "revoked" },
        { headers: { "x-codevisor-account": "user-one" } }
      )) as typeof fetch
  })
  expect((await deleted(id, { action: "read" })).status).toBe("revoked")
  expect(await deleted.cached(id)).toBeUndefined()
})
