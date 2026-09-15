import { processTree, readProcessTable, sameProcess, stopProcesses } from "./index.mjs"

/** Keep identities while a child runs so cleanup can still find descendants
 * after their parent exits. Dedicated groups also retain orphaned shells.
 * @param {number} pid
 * @param {{detached?: boolean, list?: typeof readProcessTable, stop?: typeof stopProcesses}} [options]
 */
export async function trackProcessTree(pid, options = {}) {
  const list = options.list ?? readProcessTable
  const stop = options.stop ?? stopProcesses
  const first = await list()
  const owner = first.find((entry) => entry.pid === pid)
  const known = new Map(processTree(first, [pid]).map((entry) => [entry.pid, entry]))
  let polling = Promise.resolve()
  const capture = async () => {
    const table = await list()
    const live = table.filter((entry) => sameProcess(known.get(entry.pid), entry))
    const descendants = processTree(
      table,
      live.map((entry) => entry.pid)
    )
    for (const entry of table) {
      if (
        descendants.some((child) => child.pid === entry.pid) ||
        ((owner?.pgid === pid || options.detached) &&
          entry.pgid === pid &&
          (live.length > 0 || !table.some((candidate) => candidate.pid === pid)))
      ) {
        known.set(entry.pid, entry)
      }
    }
  }
  const timer = setInterval(() => {
    polling = polling.then(capture).catch(() => undefined)
  }, 250)
  timer.unref()
  /** @type {Promise<void> | undefined} */
  let stopping
  return {
    /** @param {{graceMs?: number, includeRoot?: boolean}} [options] */
    stop: (options = {}) => {
      stopping ??= (async () => {
        clearInterval(timer)
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
    dispose: () => clearInterval(timer)
  }
}
