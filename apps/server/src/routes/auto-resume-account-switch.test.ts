import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { run } from "../test-support.js"
import {
  accountsChanged,
  advance,
  at,
  createChat,
  exhaustedUntil,
  lastUpdate,
  makeFixture,
  minutes,
  saveAccounts,
  signInFlow,
  start,
  startTurn,
  stopAtLimit
} from "./auto-resume-scheduler-test-support.js"

describe("auto-resume when the account changes", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] })
    vi.setSystemTime(start)
  })
  afterEach(() => vi.useRealTimers())

  it("resumes right away on the account the user switches to, leaving other harnesses waiting", async () => {
    const fixture = await makeFixture()
    const [claude, codex, unbound] = [
      await createChat(fixture),
      await createChat(fixture, "codex"),
      await createChat(fixture)
    ]
    for (const [id, harnessId] of [
      ["personal", "claude-code"],
      ["work", "claude-code"],
      ["codex-personal", "codex"]
    ] as const) {
      await run(
        fixture.db.saveHarnessAccount({
          id,
          harnessId,
          profileKind: "managed",
          profileKey: id,
          label: id,
          authState: "authenticated",
          canLogin: true,
          canLogout: true
        })
      )
    }
    await run(fixture.db.bindSessionHarnessAccount(claude, "personal"))
    await run(fixture.db.bindSessionHarnessAccount(codex, "codex-personal"))
    await run(fixture.db.setActiveHarnessAccount("claude-code", "personal"))
    for (const chat of [claude, codex, unbound]) await stopAtLimit(fixture, chat, at(minutes(240)))

    await accountsChanged(fixture, "claude-code")
    await accountsChanged(fixture, "codex")
    await accountsChanged(fixture, "gemini")
    expect(fixture.resumed).toEqual([])

    await run(fixture.db.setActiveHarnessAccount("claude-code", "work"))
    await accountsChanged(fixture, "claude-code")
    await advance(fixture, 0)

    expect(fixture.resumed).toEqual([claude])
    expect((await run(fixture.db.getSessionSummary(claude))).harnessAccountId).toBe("work")
    expect(await run(fixture.db.getAutoResume(codex))).toMatchObject({
      state: "waiting"
    })
    expect(await run(fixture.db.getAutoResume(unbound))).toMatchObject({
      state: "waiting"
    })
  })

  it("shows every chat moved to the new account as resuming until its own turn starts", async () => {
    const fixture = await makeFixture()
    const chats: Array<string> = []
    for (let index = 0; index < 6; index += 1) chats.push(await createChat(fixture))
    await saveAccounts(fixture, ["personal", "work"])
    for (const chat of chats) {
      await run(fixture.db.bindSessionHarnessAccount(chat, "personal"))
      await stopAtLimit(fixture, chat, at(minutes(240)))
    }

    await run(fixture.db.setActiveHarnessAccount("claude-code", "work"))
    await accountsChanged(fixture, "claude-code")
    for (const chat of chats) expect(lastUpdate(fixture, chat)).toEqual({ state: "resuming" })
    await advance(fixture, 0)

    expect(fixture.resumed).toEqual(chats.slice(0, 4))
    for (const chat of chats) expect(fixture.scheduler.progress(chat)).toBe("resuming")
    for (const chat of chats.slice(0, 2)) await startTurn(fixture, chat)
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual(chats)
    expect(chats.map((chat) => fixture.scheduler.progress(chat))).toEqual([
      undefined,
      undefined,
      "resuming",
      "resuming",
      "resuming",
      "resuming"
    ])
  })

  it("keeps waiting when the account the user switches to is limited too", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    await saveAccounts(fixture, ["personal", "work"])
    await run(fixture.db.bindSessionHarnessAccount(chat, "personal"))
    await stopAtLimit(fixture, chat, at(minutes(240)))
    fixture.limits.current = exhaustedUntil(at(minutes(90)))

    await run(fixture.db.setActiveHarnessAccount("claude-code", "work"))
    await accountsChanged(fixture, "claude-code")
    await advance(fixture, 0)

    expect(fixture.resumed).toEqual([])
    expect(lastUpdate(fixture, chat)).toEqual({
      state: "scheduled",
      resumesAt: at(minutes(90))
    })
    expect((await run(fixture.db.getSessionSummary(chat))).harnessAccountId).toBe("work")
  })

  it("goes back to waiting when the new account is limited with no known reset", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    await saveAccounts(fixture, ["personal", "work"])
    await run(fixture.db.bindSessionHarnessAccount(chat, "personal"))
    await stopAtLimit(fixture, chat, at(minutes(240)))
    fixture.limits.current = exhaustedUntil(undefined)

    await run(fixture.db.setActiveHarnessAccount("claude-code", "work"))
    await accountsChanged(fixture, "claude-code")
    await advance(fixture, 0)

    expect(fixture.resumed).toEqual([])
    expect(lastUpdate(fixture, chat)).toEqual({ state: "scheduled" })
    expect(fixture.scheduler.progress(chat)).toBeUndefined()
  })

  it("checks again right away when the stopped account finishes signing in", async () => {
    const fixture = await makeFixture()
    const [chat, other] = [await createChat(fixture), await createChat(fixture)]
    await saveAccounts(fixture, ["personal", "work"])
    await run(fixture.db.bindSessionHarnessAccount(chat, "personal"))
    await run(fixture.db.bindSessionHarnessAccount(other, "work"))
    for (const stopped of [chat, other]) await stopAtLimit(fixture, stopped, at(minutes(240)))

    await signInFlow(fixture, {
      id: "flow",
      accountId: "personal",
      kind: "browser"
    })
    await signInFlow(fixture, { id: "flow", kind: "complete" })
    await signInFlow(fixture, {
      id: "flow",
      accountId: "nobody",
      kind: "complete"
    })
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual([])

    await signInFlow(fixture, {
      id: "flow",
      accountId: "personal",
      kind: "complete"
    })
    await advance(fixture, 0)

    expect(fixture.resumed).toEqual([chat])
    expect(await run(fixture.db.getAutoResume(other))).toMatchObject({
      state: "waiting"
    })
  })
})
