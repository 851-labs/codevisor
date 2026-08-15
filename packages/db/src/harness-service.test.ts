import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { DatabaseError, makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("persists harness accounts, selection, auth state, and session bindings", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ name: "Auth", folderPath: "/tmp/auth" }))

    const defaultAccount = await run(
      db.saveHarnessAccount({
        id: "default-codex",
        harnessId: "codex",
        profileKind: "default",
        label: "Existing account",
        authState: "checking",
        canLogin: true,
        canLogout: false
      })
    )
    expect(defaultAccount.isActive).toBe(true)
    const updatedDefault = await run(
      db.saveHarnessAccount({
        id: "ignored-duplicate-id",
        harnessId: "codex",
        profileKind: "default",
        label: "Detected account",
        email: "person@example.com",
        organizationId: "org-1",
        authMethod: "chatgpt",
        authState: "authenticated",
        canLogin: true,
        canLogout: true,
        lastCheckedAt: "2026-07-10T00:00:00.000Z",
        detail: "Plus"
      })
    )
    expect(updatedDefault.id).toBe(defaultAccount.id)
    const expiredDefault = await run(
      db.updateHarnessAccountAuth(updatedDefault.id, { authState: "expired" })
    )
    expect(expiredDefault).toMatchObject({
      email: "person@example.com",
      organizationId: "org-1",
      authMethod: "chatgpt",
      detail: "Plus"
    })
    await expect(
      run(db.updateHarnessAccountAuth("missing-account", { authState: "error" }))
    ).rejects.toBeInstanceOf(DatabaseError)

    const managed = await run(
      db.saveHarnessAccount({
        id: "managed-codex",
        harnessId: "codex",
        profileKind: "managed",
        profileKey: "profile-a",
        label: "Work",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const sameManaged = await run(
      db.saveHarnessAccount({
        harnessId: "codex",
        profileKind: "managed",
        profileKey: "profile-a",
        label: "Work renamed",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    expect(sameManaged.id).toBe(managed.id)
    expect((await run(db.listHarnessAccounts("codex"))).length).toBe(2)
    expect(await run(db.getHarnessAccount("missing"))).toBeUndefined()

    const authenticated = await run(
      db.updateHarnessAccountAuth(managed.id, {
        label: "Work account",
        email: "work@example.com",
        organizationId: null,
        authMethod: "device",
        authState: "authenticated",
        canLogin: false,
        canLogout: true,
        lastCheckedAt: "2026-07-10T01:00:00.000Z",
        detail: null
      })
    )
    expect(authenticated).toMatchObject({ email: "work@example.com", canLogout: true })
    const refreshed = await run(
      db.updateHarnessAccountAuth(managed.id, { authState: "authenticated" })
    )
    expect(refreshed.organizationId).toBeUndefined()
    expect(refreshed.detail).toBeUndefined()
    await run(db.setActiveHarnessAccount("codex", managed.id))
    expect((await run(db.getHarnessAccount(managed.id)))?.isActive).toBe(true)

    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "codex", harnessAccountId: managed.id })
    )
    expect(session.harnessAccountId).toBe(managed.id)
    await expect(run(db.removeHarnessAccount(managed.id))).rejects.toBeInstanceOf(DatabaseError)
    await expect(run(db.removeHarnessAccount(defaultAccount.id))).rejects.toBeInstanceOf(
      DatabaseError
    )

    const removable = await run(
      db.saveHarnessAccount({
        harnessId: "codex",
        profileKind: "managed",
        label: "Temporary",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const passive = await run(
      db.saveHarnessAccount({
        harnessId: "claude-code",
        profileKind: "managed",
        label: "Passive",
        authState: "notRequired",
        canLogin: false,
        canLogout: true
      })
    )
    expect(passive).toMatchObject({ canLogin: false, canLogout: true })
    await run(db.updateHarnessAccountAuth(passive.id, { authState: "notRequired" }))
    await run(db.updateHarnessAccountAuth(removable.id, { authState: "unauthenticated" }))
    await expect(
      run(db.setActiveHarnessAccount("claude-code", removable.id))
    ).rejects.toBeInstanceOf(DatabaseError)
    await run(db.removeHarnessAccount(removable.id))
    expect(await run(db.getHarnessAccount(removable.id))).toBeUndefined()

    const legacy = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    expect(
      (await run(db.bindSessionHarnessAccount(legacy.id, defaultAccount.id))).harnessAccountId
    ).toBe(defaultAccount.id)
    await Effect.runPromise(db.close)
  })
})
