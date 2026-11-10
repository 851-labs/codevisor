import { existsSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { tempDirs } from "../test-support.js"
import { makeExecTasks } from "./exec-tasks.js"
import { makeMirrorStore } from "./mirror-store.js"
import { makeOrphanSweep } from "./orphan-sweep.js"
import { makeRemoteExecTasks } from "./remote-exec-tasks.js"
import { makeWorkspaceMirrors, type MirrorTransport } from "./workspace-mirrors.js"

const HOUR_MS = 60 * 60 * 1000
const GONE = "sandbox-gone"
const KEPT = "machine-kept"

const tempDir = (prefix: string): string => {
  const directory = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(directory)
  return directory
}

const unreachable = async (): Promise<never> => {
  throw new Error("Sandbox is offline")
}

const recordingTransport = (removed: string[]): MirrorTransport => ({
  prepare: unreachable,
  write: unreachable,
  apply: unreachable,
  remove: async (machineId) => {
    removed.push(machineId)
  }
})

const sweepRig = () => {
  const mirrors = makeMirrorStore(tempDir("codevisor-mirrors-"))
  const execTasks = makeExecTasks({
    directory: tempDir("codevisor-exec-"),
    shell: "/bin/sh",
    env: process.env
  })
  const remoteExecTasks = makeRemoteExecTasks({
    self: { id: "server-a", name: () => "Server A" },
    link: { invoke: unreachable },
    local: execTasks
  })
  const removed: string[] = []
  const workspaceMirrors = makeWorkspaceMirrors({
    directory: tempDir("codevisor-sync-state-"),
    transport: recordingTransport(removed),
    intervalMs: HOUR_MS,
    retryMs: HOUR_MS,
    removalRetryMs: HOUR_MS
  })
  const sweep = makeOrphanSweep({
    isGone: (machineId) => machineId === GONE,
    mirrors,
    execTasks,
    remoteExecTasks,
    workspaceMirrors,
    intervalMs: HOUR_MS
  })
  onTestFinished(() => {
    sweep.close()
    workspaceMirrors.close()
    execTasks.closeAll()
  })
  return { mirrors, execTasks, remoteExecTasks, workspaceMirrors, removed, sweep }
}

const background = (owner: string) => ({
  command: "sleep 30",
  description: `Started by ${owner}`,
  cwd: tmpdir(),
  owner
})

describe("orphan sweep", () => {
  it("cleans up only what machines that left the account started or synced", async () => {
    const rig = sweepRig()
    const orphanedCopy = await rig.mirrors.prepare("mirror-gone", "site", GONE)
    const keptCopy = await rig.mirrors.prepare("mirror-kept", "site", KEPT)
    const orphanedTask = rig.execTasks.start(background(GONE), () => undefined)
    const keptTask = rig.execTasks.start(background(KEPT), () => undefined)
    rig.remoteExecTasks.record(
      { sessionId: "chat-1", task: { ...orphanedTask, taskId: "remote-1" }, outputTail: "" },
      { id: GONE, name: "Sandbox" }
    )
    const root = tempDir("codevisor-sync-source-")
    writeFileSync(join(root, "index.html"), "<h1>hi</h1>")
    await rig.workspaceMirrors.start(
      { id: "ws-1", name: "site", root },
      { id: GONE, name: "Sandbox" }
    )

    await rig.sweep.sweep()

    expect(existsSync(orphanedCopy.path)).toBe(false)
    expect(existsSync(keptCopy.path)).toBe(true)
    expect(rig.execTasks.get(orphanedTask.taskId)?.state).toBe("stopped")
    expect(rig.execTasks.get(keptTask.taskId)?.state).toBe("running")
    expect(rig.remoteExecTasks.list()).toEqual([])
    expect(await rig.workspaceMirrors.list("ws-1")).toEqual([])
    expect(rig.workspaceMirrors.machines()).toEqual([])
    expect(rig.removed).toEqual([])
  })
})
