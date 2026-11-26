import { createHash } from "node:crypto"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { Effect } from "effect"
import { describe, expect, it, onTestFinished } from "vitest"

import {
  makeTerminalManager,
  TerminalError,
  type SavedResume,
  type TerminalManagerService,
  type TerminalSnapshot,
  type TerminalSpawner
} from "./index.js"
import { FakeProcess, inputFrame, makeSpawner, replayedFrames, run } from "./test-support.js"

const ZSH_HOOK = fileURLToPath(new URL("../resources/program-resume/zsh", import.meta.url))
const USER_ID = 501

const b64 = (text: string): string => Buffer.from(text).toString("base64")
const owner = (pid: number) => ({ pid, ppid: 1, pgid: pid, startedAt: "started", state: "S" })
const now = (): number => Math.floor(Date.now() / 1000)

const report = (token: string, body: string): string => {
  const signed = `${body}:mac=${createHash("sha256").update(`${body}:${token}`).digest("hex")}`
  return `\u001b]7577;${signed}\u001b\\`
}

const commandReport = (token: string, pid: number, argv: ReadonlyArray<string>, cwd?: string) =>
  report(
    token,
    [`pid=${pid}`, `time=${now()}`, `argv=${argv.map(b64).join(",")}`]
      .concat(cwd === undefined ? [] : [`cwd=${b64(cwd)}`])
      .join(":")
  )

const managerWith = (spawner: TerminalSpawner, userId = USER_ID) =>
  makeTerminalManager({
    spawner,
    defaultShell: "/bin/zsh",
    platform: "darwin",
    env: { HOME: "/tmp", OSC7577_TOKEN: "inherited", CODEVISOR_RESUME_FILE: "/inherited" },
    userId
  })

const nextResumeChange = (manager: TerminalManagerService): Promise<void> =>
  new Promise((resolve) => {
    const unsubscribe = manager.subscribeResumes(() => {
      unsubscribe()
      resolve()
    })
  })

const openPane = async (userId = USER_ID) => {
  const spawner = makeSpawner()
  const manager = managerWith(spawner, userId)
  const created = await run(
    manager.createTerminal({ sessionId: "pane", cwd: "/tmp", cols: 100, rows: 30 })
  )
  const process = spawner.processes[0]!
  const token = spawner.requests[0]!.env.OSC7577_TOKEN
  const emit = (data: string) => spawner.handlers[0]!.onOutput(data)
  const accept = async (pid: number, argv: ReadonlyArray<string>, cwd?: string) => {
    process.tree.members.set(pid, owner(pid))
    const changed = nextResumeChange(manager)
    emit(commandReport(token!, pid, argv, cwd))
    await changed
  }
  const saved = (): SavedResume | undefined => manager.snapshotTerminals().terminals[0]?.resume
  return { manager, created, spawner, process, token, emit, accept, saved }
}

const temporaryDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-resume-test-"))
  onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}

const restart = (snapshot: TerminalSnapshot, spawner: TerminalSpawner = makeSpawner()) => {
  const manager = managerWith(spawner)
  manager.restoreTerminals(snapshot)
  return manager
}

const cleanUpResumeFiles = (spawner: ReturnType<typeof makeSpawner>): void => {
  onTestFinished(() => {
    for (const request of spawner.requests) {
      const file = request.env.CODEVISOR_RESUME_FILE
      if (file !== undefined) rmSync(dirname(file), { recursive: true, force: true })
    }
  })
}

describe("program resume (OSC 7577)", () => {
  it("brings a reported program back in the same pane after the server restarts", async () => {
    const project = temporaryDirectory()
    const pane = await openPane()
    expect(pane.token).toMatch(/^[A-Za-z0-9_-]{43}$/u)

    await pane.accept(4242, ["claude", "--resume", "a b", ""], project)
    const snapshot = pane.manager.snapshotTerminals()
    expect(snapshot.terminals[0]?.resume).toEqual({
      argv: ["claude", "--resume", "a b", ""],
      cwd: project,
      cwdFromReport: true,
      uid: USER_ID
    })

    const spawner = makeSpawner()
    cleanUpResumeFiles(spawner)
    const restarted = restart(snapshot, spawner)
    const attached = await run(
      restarted.createTerminal({
        sessionId: "pane",
        cwd: "/tmp",
        cols: 100,
        rows: 30,
        attachOnly: true
      })
    )
    const resumed = spawner.requests[0]!
    expect(attached.terminalId).toBe(pane.created.terminalId)
    expect(resumed).toMatchObject({ cwd: project, cols: 100, rows: 30 })
    expect(resumed.env.ZDOTDIR).toBe(ZSH_HOOK)
    expect(resumed.env.OSC7577_TOKEN).not.toBe(pane.token)
    expect(readFileSync(resumed.env.CODEVISOR_RESUME_FILE!, "utf8")).toBe(
      `${project}\nclaude\n--resume\na b\n\n`
    )
    const frames = await run(replayedFrames(restarted, attached.terminalId))
    expect(frames.some((frame) => frame.type === "exit")).toBe(false)
    expect(restarted.snapshotTerminals().terminals[0]?.resume).toBeUndefined()
  })

  it("forgets a program that clears its record or exits, and falls back to an older one", async () => {
    const pane = await openPane()
    pane.process.tree.cwds.set(10, "/srv/outer")
    await pane.accept(10, ["outer"])
    await pane.accept(20, ["inner"])
    expect(pane.saved()?.argv).toEqual(["inner"])

    pane.process.tree.members.delete(20)
    expect(pane.saved()).toMatchObject({ argv: ["outer"], cwd: "/srv/outer", cwdFromReport: false })

    const cleared = nextResumeChange(pane.manager)
    pane.emit(report(pane.token!, `pid=10:time=${now()}:clear=1`))
    await cleared
    expect(pane.saved()).toBeUndefined()
  })

  it.each([
    ["a process outside the terminal", (token: string) => commandReport(token, 30, ["intruder"])],
    ["a report signed with another token", () => commandReport("not-the-token", 30, ["forged"])],
    [
      "a report that breaks the format",
      (token: string) => report(token, `pid=30:time=${now()}:argv=${b64("./relative")}`)
    ]
  ])("records nothing for %s", async (_, makeReport) => {
    const pane = await openPane()
    pane.emit(makeReport(pane.token!))
    await pane.accept(1, ["sentinel"])
    pane.process.tree.members.delete(1)
    pane.process.tree.members.set(30, owner(30))
    expect(pane.saved()).toBeUndefined()
  })

  it("gives no token to shells it cannot resume or to root, and never passes one on", async () => {
    const root = await openPane(0)
    const shSpawner = makeSpawner()
    await run(
      makeTerminalManager({
        spawner: shSpawner,
        defaultShell: "/bin/sh",
        userId: USER_ID
      }).createTerminal({ sessionId: "sh", cwd: "/tmp", cols: 80, rows: 24 })
    )
    expect(root.token).toBeUndefined()
    expect(root.spawner.requests[0]!.env.CODEVISOR_RESUME_FILE).toBeUndefined()
    expect(shSpawner.requests[0]!.env.OSC7577_TOKEN).toBeUndefined()
  })

  it.each([
    ["another user saved it", { uid: USER_ID + 1 }],
    ["its reported directory is gone", { cwd: "/nonexistent/codevisor-resume" }]
  ])("starts a plain shell instead when %s", async (_, change) => {
    const pane = await openPane()
    await pane.accept(4242, ["claude"], "/tmp")
    const snapshot = pane.manager.snapshotTerminals()
    const entry = snapshot.terminals[0]!
    const changed = {
      ...snapshot,
      terminals: [{ ...entry, resume: { ...entry.resume!, ...change } }]
    }

    const spawner = makeSpawner()
    const restarted = restart(changed, spawner)
    const frames = await run(replayedFrames(restarted, entry.terminalId))
    expect(spawner.requests).toHaveLength(1)
    expect(spawner.requests[0]!.env.CODEVISOR_RESUME_FILE).toBeUndefined()
    expect(frames.some((frame) => frame.type === "exit")).toBe(false)
  })
})

describe("restarting terminals after the server restarts", () => {
  it.each([
    ["its last folder", true],
    ["where it started when its last folder is gone", false]
  ])("brings a shell back live in the same pane, in %s, with its output", async (_, keep) => {
    const folder = temporaryDirectory()
    const pane = await openPane()
    pane.emit(`earlier output\r\n\u001b]7;kitty-shell-cwd://host${folder}\u0007`)
    const snapshot = pane.manager.snapshotTerminals()
    expect(snapshot.terminals[0]).toMatchObject({ launch: { cwd: "/tmp" }, cwd: folder })
    if (!keep) rmSync(folder, { recursive: true })

    const spawner = makeSpawner()
    const restarted = restart(snapshot, spawner)
    const attached = await run(
      restarted.createTerminal({ sessionId: "pane", cwd: "/tmp", cols: 80, rows: 24 })
    )
    const frames = await run(replayedFrames(restarted, attached.terminalId))
    expect(attached.terminalId).toBe(pane.created.terminalId)
    expect(spawner.requests).toHaveLength(1)
    expect(spawner.requests[0]).toMatchObject({ cwd: keep ? folder : "/tmp", cols: 100, rows: 30 })
    expect(spawner.requests[0]!.env.OSC7577_TOKEN).toBeDefined()
    expect(frames.map((frame) => (frame.type === "output" ? frame.data : "")).join("")).toContain(
      "earlier output"
    )
    expect(frames.some((frame) => frame.type === "exit")).toBe(false)
  })

  it("shows the pane as exited when the shell cannot start again", async () => {
    const pane = await openPane()
    const snapshot = pane.manager.snapshotTerminals()
    const failing: TerminalSpawner = {
      spawn: () => Effect.fail(new TerminalError({ operation: "spawn", message: "no shell" }))
    }

    const restarted = restart(snapshot, failing)
    const exited = Promise.withResolvers<void>()
    await run(
      restarted.connectTerminal(snapshot.terminals[0]!.terminalId, 0, (frame) => {
        if (frame.type === "exit") exited.resolve()
      })
    )
    await exited.promise
    expect(restarted.snapshotTerminals().terminals).toEqual([])
  })

  it("delivers what the user types while the shell is still starting", async () => {
    const pane = await openPane()
    const snapshot = pane.manager.snapshotTerminals()
    const terminalId = snapshot.terminals[0]!.terminalId
    const started = Promise.withResolvers<FakeProcess>()
    const delayed: TerminalSpawner = { spawn: () => Effect.promise(() => started.promise) }

    const restarted = restart(snapshot, delayed)
    await run(restarted.handleClientFrame(terminalId, inputFrame(1, "typed early")))
    const process = new FakeProcess()
    const delivered = Promise.withResolvers<string>()
    process.write = (data) => delivered.resolve(data)
    started.resolve(process)
    expect(await delivered.promise).toBe("typed early")
  })

  it("stops the new shell when the pane is closed while it is still starting", async () => {
    const pane = await openPane()
    const snapshot = pane.manager.snapshotTerminals()
    const started = Promise.withResolvers<FakeProcess>()
    const delayed: TerminalSpawner = { spawn: () => Effect.promise(() => started.promise) }

    const restarted = restart(snapshot, delayed)
    await run(restarted.closeTerminal(snapshot.terminals[0]!.terminalId))
    const process = new FakeProcess()
    const killed = Promise.withResolvers<void>()
    process.kill = () => killed.resolve()
    started.resolve(process)
    await killed.promise
    expect(restarted.snapshotTerminals().terminals).toEqual([])
  })

  it.each([
    ["a shell prompt", "one\r\ntwo\r\nthree", "one\ntwo\nthree\nback"],
    ["a full-screen program", "shell\r\n\u001b[?1049hfull screen", "back"]
  ])("draws the new shell below the output left by %s", async (_, before, after) => {
    const pane = await openPane()
    pane.emit(before)
    const snapshot = pane.manager.snapshotTerminals()

    const spawner = makeSpawner()
    const restarted = restart(snapshot, spawner)
    spawner.handlers[0]!.onOutput("back")
    const screen = await run(restarted.readScreen(snapshot.terminals[0]!.terminalId, "text"))
    expect(screen).toBe(after)
  })
})
