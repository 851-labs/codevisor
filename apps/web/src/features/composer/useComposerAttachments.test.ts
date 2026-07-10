import { describe, expect, it } from "vitest"

import {
  ComposerAttachmentStoreCache,
  type ComposerAttachmentStore
} from "./useComposerAttachments"

describe("composer attachment store cache", () => {
  it("returns the same session store across route remounts", () => {
    const cache = new ComposerAttachmentStoreCache(2, () => undefined)
    const first = cache.get("session-a")

    expect(cache.get("session-a")).toBe(first)
  })

  it("evicts only idle stores and preserves mounted or uploading drafts", () => {
    const evicted: ComposerAttachmentStore[] = []
    const cache = new ComposerAttachmentStoreCache(2, (store) => evicted.push(store))
    const idle = cache.get("idle")
    const mounted = cache.get("mounted")
    cache.retain(mounted)
    const uploading = cache.get("uploading")
    uploading.uploadTasks.set("file", new Promise(() => undefined))
    cache.retain(uploading)

    expect(cache.has("idle")).toBe(false)
    expect(cache.has("mounted")).toBe(true)
    expect(cache.has("uploading")).toBe(true)
    expect(evicted).toEqual([idle])
  })
})
