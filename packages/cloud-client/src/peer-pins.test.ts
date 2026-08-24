import { describe, expect, it } from "vitest"
import { makePeerKeyPinStore, parsePeerKeyPins, serializePeerKeyPins } from "./peer-pins.js"

describe("parsePeerKeyPins", () => {
  it("round-trips through serialize", () => {
    const peers = { "app-1": "key-1", "app-2": "key-2" }
    expect(parsePeerKeyPins(serializePeerKeyPins(peers))).toEqual(peers)
  })

  it("tolerates corrupt or unrecognized content with an empty pin set", () => {
    expect(parsePeerKeyPins("")).toEqual({})
    expect(parsePeerKeyPins("{not json")).toEqual({})
    expect(parsePeerKeyPins(JSON.stringify({ version: 2, peers: { a: "k" } }))).toEqual({})
    expect(parsePeerKeyPins(JSON.stringify({ version: 1, peers: null }))).toEqual({})
    expect(parsePeerKeyPins(JSON.stringify({ version: 1, peers: "nope" }))).toEqual({})
  })

  it("drops non-string pin values instead of trusting them", () => {
    const raw = JSON.stringify({ version: 1, peers: { good: "key", bad: 7 } })
    expect(parsePeerKeyPins(raw)).toEqual({ good: "key" })
  })
})

describe("makePeerKeyPinStore", () => {
  it("pins first-seen keys and never overwrites an existing pin", () => {
    const persisted: Record<string, string>[] = []
    const store = makePeerKeyPinStore({
      initial: { "app-1": "original" },
      persist: (peers) => persisted.push({ ...peers })
    })

    expect(store.get("app-1")).toBe("original")
    expect(store.get("app-2")).toBeUndefined()

    store.set("app-2", "fresh")
    expect(store.get("app-2")).toBe("fresh")
    expect(persisted).toEqual([{ "app-1": "original", "app-2": "fresh" }])

    // set() is TOFU: re-pinning is a no-op, not an update — and nothing is
    // re-persisted for it.
    store.set("app-1", "attacker")
    expect(store.get("app-1")).toBe("original")
    expect(persisted).toHaveLength(1)
  })

  it("works without persistence wired up", () => {
    const store = makePeerKeyPinStore({})
    store.set("app-1", "key")
    expect(store.get("app-1")).toBe("key")
  })
})
