import { processTree, readProcessTable, sameProcess, stopProcesses } from "./index.mjs"

/** Drop argv and detach strings, including for injected process readers.
 * @param {import('./index.mjs').ProcessIdentity} entry
 * @returns {import('./index.mjs').ProcessIdentity}
 */
const identity = (entry) => ({
  pid: entry.pid,
  ppid: entry.ppid,
  pgid: entry.pgid,
  startedAt: Buffer.from(entry.startedAt).toString(),
  state: Buffer.from(entry.state).toString()
})

/** Keep the initial full table out of the long-lived tracker's closure.
 * @param {number} pid
 * @param {import('./index.mjs').ProcessIdentity[]} table
 * @param {boolean} detached
 */
const initialState = (pid, table, detached) => {
  const root = table.find((entry) => entry.pid === pid)
  const group = root?.pgid === pid || detached
  const descendants = new Set(processTree(table, [pid]).map((entry) => entry.pid))
  return {
    owner: root === undefined ? undefined : identity(root),
    group: group && table.some((entry) => entry.pgid === pid && !entry.state.startsWith("Z")),
    known: new Map(
      table
        .filter(
          (entry) =>
            !entry.state.startsWith("Z") &&
            (descendants.has(entry.pid) || (group && entry.pgid === pid))
        )
        .map((entry) => [entry.pid, identity(entry)])
    )
  }
}

/** Keep identities while a child runs so cleanup can still find descendants
 * after their parent exits. Dedicated groups also retain orphaned shells.
 * @param {number} pid
 * @param {{detached?: boolean, list?: () => Promise<import('./index.mjs').ProcessIdentity[]>, stop?: typeof stopProcesses}} [options]
 */
export async function trackProcessTree(pid, options = {}) {
  const list = options.list ?? (() => readProcessTable({ includeCommand: false }))
  const stop = options.stop ?? stopProcesses
  const { owner, known, group } = initialState(pid, await list(), options.detached ?? false)
  let trackGroup = group
  let polling = Promise.resolve()
  const capture = async () => {
    const table = await list()
    const live = table.filter((entry) => sameProcess(known.get(entry.pid), entry))
    const descendants = new Set(
      processTree(
        table,
        live.map((entry) => entry.pid)
      ).map((entry) => entry.pid)
    )
    const root = table.find((entry) => entry.pid === pid)
    // A dedicated group survives its leader, but must never attach to a new
    // owner after the group disappears or its leader's PID is reused.
    trackGroup &&=
      (root === undefined || root.startedAt === owner?.startedAt) &&
      table.some((entry) => entry.pgid === pid && !entry.state.startsWith("Z"))
    // Discover surviving descendants before pruning dead identities. This
    // preserves reparented children without accumulating every exited command.
    known.clear()
    for (const entry of table) {
      if (
        !entry.state.startsWith("Z") &&
        (descendants.has(entry.pid) || (trackGroup && entry.pgid === pid))
      ) {
        known.set(entry.pid, identity(entry))
      }
    }
  }
  let disposed = false
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  let timer
  /** @returns {void} */
  const schedule = () => {
    if (disposed) return
    timer = setTimeout(() => {
      polling = capture()
        .catch(() => undefined)
        .then(schedule)
    }, 250)
    timer.unref()
  }
  const dispose = () => {
    disposed = true
    clearTimeout(timer)
  }
  schedule()
  /** @type {Promise<void> | undefined} */
  let stopping
  return {
    /** @param {{graceMs?: number, includeRoot?: boolean}} [options] */
    stop: (options = {}) => {
      stopping ??= (async () => {
        dispose()
        await polling
        await capture()
        await stop(
          [...known.values()].filter((entry) => options.includeRoot !== false || entry.pid !== pid),
          options
        )
      })().catch((error) => {
        stopping = undefined
        throw error
      })
      return stopping
    },
    dispose
  }
}
