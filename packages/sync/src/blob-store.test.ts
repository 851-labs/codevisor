import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { isValidBlobId, makeBlobStore } from "./blob-store.js"

const id = "a".repeat(64)

describe("blob store", () => {
  let directory: string

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "blob-store-"))
  })

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true })
  })

  it("round-trips bytes by id", async () => {
    const store = makeBlobStore(join(directory, "blobs"))
    expect(store.has(id)).toBe(false)

    store.write(id, new TextEncoder().encode("archive-bytes"))
    expect(store.has(id)).toBe(true)
    expect((await store.read(id)).toString()).toBe("archive-bytes")
    expect(store.path(id)).toContain(id)

    store.remove(id)
    expect(store.has(id)).toBe(false)
    // Removing again is a no-op.
    store.remove(id)
  })

  it("refuses ids that are not 64 hex characters", () => {
    const store = makeBlobStore(directory)
    expect(isValidBlobId(id)).toBe(true)
    expect(isValidBlobId("ABC")).toBe(false)
    expect(isValidBlobId("../escape")).toBe(false)
    expect(() => store.has("not-a-hash")).toThrow(/Invalid blob id/)
  })
})
