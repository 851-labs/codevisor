import type { CredentialSource } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import { CREDENTIALS_SYNC_NAMESPACE, reconcileCredentials } from "./credential-sync.js"

const makeFakeSource = (id: string, tombstoneOnAbsence = false) => {
  const state: { content: string | undefined; failing: boolean; applies: number } = {
    content: undefined,
    failing: false,
    applies: 0
  }
  const source: CredentialSource = {
    id,
    tombstoneOnAbsence,
    read: () => {
      if (state.failing) return Promise.reject("unreadable")
      return Promise.resolve(state.content)
    },
    apply: (content) => {
      state.applies += 1
      state.content = content
      return Promise.resolve()
    },
    applyDelete: () => {
      state.applies += 1
      state.content = undefined
      return Promise.resolve()
    }
  }
  return { source, state }
}

const makeMachine = async (serverId: string, nowMs: number) => {
  const { services } = await makeServices(serverId)
  const pi = makeFakeSource("pi-auth")
  const codex = makeFakeSource("codex-auth-file", true)
  const appliedIds: string[] = []
  const deps = {
    db: services.db,
    serverId,
    now: () => nowMs,
    sources: [pi.source, codex.source],
    onApplied: (sourceId: string) => appliedIds.push(sourceId)
  }
  return { services, deps, pi, codex, appliedIds }
}

describe("credential sync", () => {
  it("applies shared profile metadata before credentials and reports profile failures independently", async () => {
    const machine = await makeMachine("profiles", 1000)
    const profile = makeFakeSource("opencode-profile:work")
    const seen: Array<string | undefined> = []
    const profileSources = async (content?: string) => {
      seen.push(content)
      return [profile.source]
    }
    await reconcileCredentials({ ...machine.deps, profileSources })
    expect(seen).toEqual([])
    await run(
      machine.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, [
        {
          key: "profiles:opencode",
          value: "profiles",
          timestamp: { wallMs: 1, counter: 0, deviceId: "global" }
        },
        {
          key: profile.source.id,
          value: "key",
          timestamp: { wallMs: 1, counter: 0, deviceId: "global" }
        }
      ])
    )
    await reconcileCredentials(machine.deps)
    expect(profile.state.content).toBeUndefined()
    await reconcileCredentials({ ...machine.deps, profileSources })
    expect(seen).toEqual(["profiles"])
    expect(profile.state.content).toBe("key")
    const failed = await reconcileCredentials({
      ...machine.deps,
      profileSources: async () => {
        throw new Error("Profile in use")
      }
    })
    expect(failed.status.failed).toEqual([{ id: "profiles:opencode", reason: "Profile in use" }])
    await run(
      machine.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, [
        {
          key: "profiles:opencode",
          value: null,
          deleted: true,
          timestamp: { wallMs: 2, counter: 0, deviceId: "global" }
        }
      ])
    )
    await reconcileCredentials({ ...machine.deps, profileSources })
    expect(seen).toEqual(["profiles", undefined])
  })

  it("keeps shared credentials when a machine signs in locally and restores them after local sign-out", async () => {
    const machine = await makeMachine("local-auth", 1000)
    let overrides: string[] = []
    Object.assign(machine.codex.source, { localOverrides: () => Promise.resolve(overrides) })
    machine.codex.state.content = '{"OPENAI_API_KEY":"shared"}'
    await reconcileCredentials(machine.deps)
    overrides = ["*"]
    machine.codex.state.content = undefined
    const localLogin = await reconcileCredentials(machine.deps)
    expect(localLogin.status.published).toEqual([])
    expect(localLogin.status.removed).toEqual([])
    expect((await reconcileCredentials(machine.deps)).changedEntries).toEqual([])

    overrides = []
    const signedOut = await reconcileCredentials({ ...machine.deps })
    expect(signedOut.status.published).toEqual([])
    expect(signedOut.status.applied).toEqual(["codex-auth-file"])
    expect(machine.codex.state.content).toBe('{"OPENAI_API_KEY":"shared"}')
    expect((await reconcileCredentials(machine.deps)).status.applied).toEqual([])
  })

  it("ferries static credentials across machines with fleet-first joins", async () => {
    const a = await makeMachine("cred-a", 1_000)
    const b = await makeMachine("cred-b", 2_000)

    a.pi.state.content = '{"openai":{"key":"sk-1","type":"api_key"}}'
    const first = await reconcileCredentials(a.deps)
    expect(first.status.published).toEqual(["pi-auth"])
    expect((await reconcileCredentials(a.deps)).changedEntries).toEqual([])

    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, first.changedEntries))
    const adopted = await reconcileCredentials(b.deps)
    expect(adopted.status.applied).toEqual(["pi-auth"])
    expect(b.pi.state.content).toBe(a.pi.state.content)
    expect(b.appliedIds).toEqual(["pi-auth"])
    const applies = b.pi.state.applies
    expect((await reconcileCredentials(b.deps)).changedEntries).toEqual([])
    expect(b.pi.state.applies).toBe(applies)

    const c = await makeMachine("cred-c", 3_000)
    c.pi.state.content = '{"openai":{"key":"local-divergent","type":"api_key"}}'
    await run(c.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, first.changedEntries))
    const joined = await reconcileCredentials(c.deps)
    expect(joined.status.published).toEqual([])
    expect(joined.status.applied).toEqual(["pi-auth"])
    expect(c.pi.state.content).toBe(a.pi.state.content)

    const d = await makeMachine("cred-d", 4_000)
    d.pi.state.content = a.pi.state.content
    await run(d.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, first.changedEntries))
    const matching = await reconcileCredentials(d.deps)
    expect(matching.status).toMatchObject({ published: [], applied: [], failed: [] })
    expect(d.pi.state.applies).toBe(0)

    c.pi.state.content = '{"openai":{"key":"sk-2","type":"api_key"}}'
    const edited = await reconcileCredentials(c.deps)
    expect(edited.status.published).toEqual(["pi-auth"])
    await run(a.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, edited.changedEntries))
    await reconcileCredentials(a.deps)
    expect(a.pi.state.content).toBe(c.pi.state.content)
  })

  it("propagates sign-outs only for tombstoneOnAbsence sources", async () => {
    const a = await makeMachine("cred-del-a", 1_000)
    const b = await makeMachine("cred-del-b", 2_000)
    a.codex.state.content = '{"OPENAI_API_KEY":"sk-c"}'
    a.pi.state.content = '{"openai":{"key":"sk-1","type":"api_key"}}'
    const seeded = await reconcileCredentials(a.deps)
    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, seeded.changedEntries))
    await reconcileCredentials(b.deps)
    expect(b.codex.state.content).toBe('{"OPENAI_API_KEY":"sk-c"}')

    a.codex.state.content = undefined
    a.pi.state.content = undefined
    const signedOut = await reconcileCredentials(a.deps)
    expect(signedOut.status.published).toEqual(["codex-auth-file"])
    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, signedOut.changedEntries))
    const removedOnB = await reconcileCredentials(b.deps)
    expect(removedOnB.status.removed).toEqual(["codex-auth-file"])
    expect(b.codex.state.content).toBeUndefined()
    expect(b.pi.state.content).not.toBeUndefined()
    expect((await reconcileCredentials(b.deps)).changedEntries).toEqual([])
  })

  it("keeps the local credential when a sign-out arrives for a source that cannot delete", async () => {
    const a = await makeMachine("cred-keep-a", 1_000)
    const b = await makeMachine("cred-keep-b", 2_000)
    a.codex.state.content = '{"OPENAI_API_KEY":"sk-c"}'
    const seeded = await reconcileCredentials(a.deps)
    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, seeded.changedEntries))
    const { applyDelete: _unused, ...withoutDelete } = b.codex.source
    const deps = { ...b.deps, sources: [b.pi.source, withoutDelete] }
    await reconcileCredentials(deps)

    a.codex.state.content = undefined
    const signedOut = await reconcileCredentials(a.deps)
    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, signedOut.changedEntries))
    const kept = await reconcileCredentials(deps)
    expect(kept.status).toMatchObject({ removed: [], failed: [] })
    expect(b.codex.state.content).toBe('{"OPENAI_API_KEY":"sk-c"}')
  })

  it("isolates apply and delete failures without baselining them", async () => {
    const a = await makeMachine("cred-apply-a", 1_000)
    const b = await makeMachine("cred-apply-b", 2_000)
    a.pi.state.content = '{"openai":{"key":"sk-1","type":"api_key"}}'
    a.codex.state.content = '{"OPENAI_API_KEY":"sk-c"}'
    const seeded = await reconcileCredentials(a.deps)
    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, seeded.changedEntries))

    const applyOnce = b.pi.source.apply
    let applyCalls = 0
    Object.assign(b.pi.source, {
      apply: (content: string) => {
        applyCalls += 1
        if (applyCalls === 1) return Promise.reject(new Error("disk full"))
        return applyOnce(content)
      }
    })
    const failing = await reconcileCredentials(b.deps)
    expect(failing.status.failed).toEqual([{ id: "pi-auth", reason: "disk full" }])
    expect((await reconcileCredentials(b.deps)).status.applied).toContain("pi-auth")

    a.codex.state.content = undefined
    const signedOut = await reconcileCredentials(a.deps)
    await run(b.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, signedOut.changedEntries))
    const deleteOnce = b.codex.source.applyDelete!
    let deleteCalls = 0
    Object.assign(b.codex.source, {
      applyDelete: () => {
        deleteCalls += 1
        if (deleteCalls === 1) return Promise.reject(new Error("locked"))
        return deleteOnce()
      }
    })
    const failingDelete = await reconcileCredentials(b.deps)
    expect(failingDelete.status.failed).toEqual([{ id: "codex-auth-file", reason: "locked" }])
    expect((await reconcileCredentials(b.deps)).status.removed).toEqual(["codex-auth-file"])
  })

  it("isolates per-source failures and retries them next pass", async () => {
    const a = await makeMachine("cred-fail", 1_000)
    a.pi.state.failing = true
    a.codex.state.content = '{"OPENAI_API_KEY":"still-works"}'
    await run(
      a.services.db.mergeSyncEntries(CREDENTIALS_SYNC_NAMESPACE, [
        {
          key: "alien-source",
          value: '{"not":"ours"}',
          timestamp: { wallMs: 5, counter: 0, deviceId: "elsewhere" }
        },
        {
          key: "pi-auth",
          value: { malformed: true },
          timestamp: { wallMs: 6, counter: 0, deviceId: "elsewhere" }
        }
      ])
    )
    const pass = await reconcileCredentials(a.deps)
    expect(pass.status.failed).toEqual([{ id: "pi-auth", reason: "unreadable" }])
    expect(pass.status.published).toEqual(["codex-auth-file"])
    expect(pass.status.applied).toEqual([])

    a.pi.state.failing = false
    const healed = await reconcileCredentials(a.deps)
    expect(healed.status).toMatchObject({ applied: [], failed: [] })

    a.pi.state.content = '{"openai":{"key":"sk-1","type":"api_key"}}'
    expect((await reconcileCredentials(a.deps)).status.published).toEqual(["pi-auth"])
  })
})
