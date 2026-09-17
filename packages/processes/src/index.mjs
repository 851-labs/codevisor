import { execFile } from "node:child_process"
import { setTimeout as sleep } from "node:timers/promises"
import { promisify } from "node:util"

export { trackProcessTree } from "./tracker.mjs"

const exec = promisify(execFile)

/** @typedef {{pid: number, ppid: number, pgid: number, startedAt: string, state: string}} ProcessIdentity */
/** @typedef {ProcessIdentity & {command: string}} ProcessTableEntry */
/** @typedef {{list: () => Promise<ProcessIdentity[]>, signal: (pid: number, signal: NodeJS.Signals) => void, now: () => number, sleep: (ms: number) => Promise<unknown>}} ProcessSystem */

/** Parse a locale-independent `ps` snapshot, including birth time to reject reused PIDs.
 * @param {string} output
 * @returns {ProcessTableEntry[]}
 */
export function parseProcessTable(output) {
  return output.split("\n").flatMap((line) => {
    const match = line.match(
      /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d+)\s+(\S+)(?:\s+(.*))?$/
    )
    if (!match) return []
    return [
      {
        pid: Number(match[1]),
        ppid: Number(match[2]),
        pgid: Number(match[3]),
        // RegExp captures can be slices of the entire ps snapshot. A caller
        // retaining one process must not keep every other process's argv alive.
        startedAt: Buffer.from((match[4] ?? "").replace(/\s+/g, " ")).toString(),
        state: Buffer.from(match[5] ?? "").toString(),
        command: Buffer.from(match[6] ?? "").toString()
      }
    ]
  })
}

/** @param {{includeCommand?: boolean}} [options]
 * @returns {Promise<ProcessTableEntry[]>} */
export async function readProcessTable({ includeCommand = true } = {}) {
  const fields = `pid=,ppid=,pgid=,lstart=,stat=${includeCommand ? ",command=" : ""}`
  const { stdout } = await exec("ps", ["-axo", fields], {
    env: { ...process.env, LC_ALL: "C" },
    maxBuffer: 16 * 1024 * 1024
  })
  return parseProcessTable(stdout)
}

/** @type {ProcessSystem} */
const nativeSystem = {
  list: () => readProcessTable({ includeCommand: false }),
  signal: (pid, signal) => {
    process.kill(pid, signal)
  },
  now: () => performance.now(),
  sleep
}

/** @param {ProcessIdentity | undefined} expected @param {ProcessIdentity | undefined} actual */
export function sameProcess(expected, actual) {
  return (
    expected !== undefined &&
    actual !== undefined &&
    expected.pid === actual.pid &&
    expected.startedAt === actual.startedAt &&
    !actual.state.startsWith("Z")
  )
}

/** @param {number} pid @returns {Promise<ProcessIdentity | undefined>} */
export async function processIdentity(pid) {
  return (await readProcessTable()).find(
    (entry) => entry.pid === pid && !entry.state.startsWith("Z")
  )
}

/** Include descendants before signalling any parent so reparenting cannot lose them.
 * @template {ProcessIdentity} T
 * @param {T[]} table @param {number[]} roots @param {boolean} includeRoots
 */
export function processTree(table, roots, includeRoots = true) {
  const selected = new Set(roots)
  let changed = true
  while (changed) {
    changed = false
    for (const entry of table) {
      if (selected.has(entry.ppid) && !selected.has(entry.pid)) {
        selected.add(entry.pid)
        changed = true
      }
    }
  }
  return table.filter(
    (entry) => selected.has(entry.pid) && (includeRoots || !roots.includes(entry.pid))
  )
}

/** Stop only captured processes and descendants. Give supervisors time to release external
 * resources before escalation; keep following captured children after their parents exit.
 * @param {ProcessIdentity[]} initial
 * @param {{graceMs?: number, forceMs?: number, system?: ProcessSystem}} [options]
 */
export async function stopProcesses(initial, options = {}) {
  const system = options.system ?? nativeSystem
  const graceMs = options.graceMs ?? 10_000
  const forceMs = options.forceMs ?? 2_000
  const known = new Map(
    initial
      .filter((entry) => entry.pid > 1 && entry.pid !== process.pid)
      .map((entry) => [entry.pid, entry])
  )
  const signalled = new Set()
  const initialIds = new Set(known.keys())
  const deadline = system.now() + graceMs
  const forceDeadline = deadline + forceMs
  while (known.size > 0) {
    const table = await system.list()
    const live = table.filter((entry) => sameProcess(known.get(entry.pid), entry))
    const descendants = processTree(
      table,
      live.map((entry) => entry.pid)
    )
    // Dedicated process groups retain children whose parent exited between snapshots.
    const groups = new Set(
      live.filter((entry) => known.get(entry.pgid)?.pid === entry.pgid).map((entry) => entry.pgid)
    )
    for (const entry of table) {
      if (
        (descendants.some((child) => child.pid === entry.pid) || groups.has(entry.pgid)) &&
        entry.pid !== process.pid &&
        !entry.state.startsWith("Z")
      ) {
        known.set(entry.pid, entry)
      }
    }
    const remaining = table.filter((entry) => sameProcess(known.get(entry.pid), entry))
    if (remaining.length === 0) return
    const signal = system.now() < deadline ? "SIGTERM" : "SIGKILL"
    for (const entry of remaining) {
      // Shutdown handlers may spawn commands to release external resources.
      // Track those commands, but let them finish during the grace period.
      if (signal === "SIGTERM" && !initialIds.has(entry.pid)) continue
      const key = `${entry.pid}:${entry.startedAt}:${signal}`
      if (signalled.has(key)) continue
      // Recheck immediately before signalling, after any async scheduling above.
      const current = (await system.list()).find((candidate) => candidate.pid === entry.pid)
      if (!sameProcess(entry, current)) continue
      try {
        system.signal(entry.pid, signal)
      } catch (error) {
        if (/** @type {NodeJS.ErrnoException} */ (error).code !== "ESRCH") throw error
      }
      signalled.add(key)
    }
    if (system.now() >= forceDeadline) {
      const finalTable = await system.list()
      const survivors = remaining.filter((entry) =>
        sameProcess(
          entry,
          finalTable.find((candidate) => candidate.pid === entry.pid)
        )
      )
      if (survivors.length)
        throw new Error(`Processes did not exit: ${survivors.map((entry) => entry.pid).join(", ")}`)
      return
    }
    await system.sleep(50)
  }
}

/** @param {number} pid @param {{includeRoot?: boolean, graceMs?: number, forceMs?: number, system?: ProcessSystem, identity?: ProcessIdentity}} [options] */
export async function stopProcessTree(pid, options = {}) {
  if (
    !Number.isSafeInteger(pid) ||
    pid <= 1 ||
    (pid === process.pid && options.includeRoot !== false)
  )
    throw new Error("Refusing to stop an invalid process owner")
  const table = await (options.system ?? nativeSystem).list()
  if (
    options.identity &&
    !sameProcess(
      options.identity,
      table.find((entry) => entry.pid === pid)
    )
  )
    return
  await stopProcesses(processTree(table, [pid], options.includeRoot ?? true), options)
}
