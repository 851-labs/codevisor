import { cp, lstat, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises"
import { renameSync } from "node:fs"
import { join } from "node:path"
import { PluginsError } from "./plugins-error.js"

export type PluginTransactionPhase =
  | "prepared"
  | "stopped"
  | "dataBackedUp"
  | "codeBackedUp"
  | "candidateInstalled"
  | "verified"

interface PluginTransactionJournal {
  readonly schemaVersion: 1
  readonly pluginId: string
  readonly phase: PluginTransactionPhase
  readonly hadExisting: boolean
  readonly hadData: boolean
}

export interface PluginTransactionPaths {
  readonly destination: string
  readonly candidate: string
  readonly codeBackup: string
  readonly data: string
  readonly dataBackup: string
  readonly journal: string
  readonly knownGoodCode: string
  readonly knownGoodData: string
}

export interface PluginTransactionEngine {
  readonly paths: (pluginId: string) => PluginTransactionPaths
  readonly withLock: <Value>(pluginId: string, operation: () => Promise<Value>) => Promise<Value>
  readonly apply: (pluginId: string, hadExisting: boolean) => Promise<void>
  readonly recover: () => Promise<void>
  readonly recoverPlugin: (pluginId: string) => Promise<void>
}

export interface PluginTransactionDeps {
  readonly pluginsRoot: string
  readonly pluginDataRoot: string
  readonly stop: (pluginId: string) => void
  readonly verifyInstalled: (pluginId: string) => Promise<void>
}

const TRANSACTIONS_DIRECTORY = ".codevisor-transactions"
const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/
const JOURNAL_PATTERN = /^([a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*)\.json$/

const exists = async (path: string): Promise<boolean> =>
  lstat(path).then(
    () => true,
    () => false
  )

const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const makePluginTransactionEngine = (
  deps: PluginTransactionDeps
): PluginTransactionEngine => {
  const transactionsRoot = join(deps.pluginsRoot, TRANSACTIONS_DIRECTORY)
  const dataTransactionsRoot = join(deps.pluginDataRoot, TRANSACTIONS_DIRECTORY)
  const locks = new Map<string, Promise<void>>()

  const paths = (pluginId: string): PluginTransactionPaths => {
    if (!PLUGIN_ID_PATTERN.test(pluginId)) {
      throw new PluginsError("invalid", `Invalid plugin transaction id: ${pluginId}`)
    }
    return {
      candidate: join(transactionsRoot, `${pluginId}.candidate`),
      codeBackup: join(transactionsRoot, `${pluginId}.code-backup`),
      data: join(deps.pluginDataRoot, pluginId),
      dataBackup: join(dataTransactionsRoot, `${pluginId}.data-backup`),
      destination: join(deps.pluginsRoot, pluginId),
      journal: join(transactionsRoot, `${pluginId}.json`),
      knownGoodCode: join(deps.pluginsRoot, `.${pluginId}.known-good`),
      knownGoodData: join(deps.pluginDataRoot, `.${pluginId}.known-good`)
    }
  }

  const writeJournal = async (journal: PluginTransactionJournal): Promise<void> => {
    const transactionPaths = paths(journal.pluginId)
    await mkdir(transactionsRoot, { recursive: true })
    const temporary = `${transactionPaths.journal}.tmp`
    await writeFile(temporary, `${JSON.stringify(journal, undefined, 2)}\n`, "utf8")
    await rename(temporary, transactionPaths.journal)
  }

  const promoteKnownGood = async (journal: PluginTransactionJournal): Promise<void> => {
    const transactionPaths = paths(journal.pluginId)
    if (journal.hadExisting && (await exists(transactionPaths.codeBackup))) {
      await rm(transactionPaths.knownGoodCode, { force: true, recursive: true })
      await rename(transactionPaths.codeBackup, transactionPaths.knownGoodCode)
    } else if (!journal.hadExisting) {
      await rm(transactionPaths.knownGoodCode, { force: true, recursive: true })
    }
    if (journal.hadData && (await exists(transactionPaths.dataBackup))) {
      await rm(transactionPaths.knownGoodData, { force: true, recursive: true })
      await rename(transactionPaths.dataBackup, transactionPaths.knownGoodData)
    } else if (!journal.hadData) {
      await rm(transactionPaths.knownGoodData, { force: true, recursive: true })
    }
    await rm(transactionPaths.candidate, { force: true, recursive: true })
    await rm(transactionPaths.journal, { force: true })
  }

  const restore = async (journal: PluginTransactionJournal, restart: boolean): Promise<void> => {
    const transactionPaths = paths(journal.pluginId)
    deps.stop(journal.pluginId)
    if (await exists(transactionPaths.codeBackup)) {
      await rm(transactionPaths.destination, { force: true, recursive: true })
      await rename(transactionPaths.codeBackup, transactionPaths.destination)
    } else if (!journal.hadExisting) {
      await rm(transactionPaths.destination, { force: true, recursive: true })
    }
    const dataMayHaveChanged =
      journal.phase === "dataBackedUp" ||
      journal.phase === "codeBackedUp" ||
      journal.phase === "candidateInstalled" ||
      /* v8 ignore next -- only reachable if the atomic verified-journal write itself fails. */
      journal.phase === "verified"
    if (dataMayHaveChanged) {
      await rm(transactionPaths.data, { force: true, recursive: true })
      if (journal.hadData && (await exists(transactionPaths.dataBackup))) {
        await rename(transactionPaths.dataBackup, transactionPaths.data)
      }
    }
    await rm(transactionPaths.candidate, { force: true, recursive: true })
    await rm(transactionPaths.dataBackup, { force: true, recursive: true })
    await rm(transactionPaths.journal, { force: true })
    if (restart && journal.hadExisting) {
      await deps.verifyInstalled(journal.pluginId)
    }
  }

  const readJournal = async (pluginId: string): Promise<PluginTransactionJournal | undefined> => {
    const path = paths(pluginId).journal
    let value: unknown
    try {
      value = JSON.parse(await readFile(path, "utf8"))
    } catch {
      return undefined
    }
    if (typeof value !== "object" || value === null) return undefined
    const journal = value as Partial<PluginTransactionJournal>
    const phases: ReadonlyArray<PluginTransactionPhase> = [
      "prepared",
      "stopped",
      "dataBackedUp",
      "codeBackedUp",
      "candidateInstalled",
      "verified"
    ]
    return journal.schemaVersion === 1 &&
      journal.pluginId === pluginId &&
      typeof journal.hadExisting === "boolean" &&
      typeof journal.hadData === "boolean" &&
      phases.some((phase) => phase === journal.phase)
      ? (journal as PluginTransactionJournal)
      : undefined
  }

  const recoverPlugin = async (pluginId: string): Promise<void> => {
    const transactionPaths = paths(pluginId)
    if (!(await exists(transactionPaths.journal))) {
      await rm(transactionPaths.candidate, { force: true, recursive: true })
      if (await exists(transactionPaths.codeBackup)) {
        if (await exists(transactionPaths.destination)) {
          await rm(transactionPaths.knownGoodCode, { force: true, recursive: true })
          await rename(transactionPaths.codeBackup, transactionPaths.knownGoodCode)
        } else {
          await rename(transactionPaths.codeBackup, transactionPaths.destination)
        }
      }
      if (await exists(transactionPaths.dataBackup)) {
        if (await exists(transactionPaths.data)) {
          await rm(transactionPaths.knownGoodData, { force: true, recursive: true })
          await rename(transactionPaths.dataBackup, transactionPaths.knownGoodData)
        } else {
          await rename(transactionPaths.dataBackup, transactionPaths.data)
        }
      }
      return
    }
    const journal = await readJournal(pluginId)
    if (journal?.phase === "verified") {
      await promoteKnownGood(journal)
      return
    }
    if (journal !== undefined) {
      await restore(journal, false)
      return
    }

    // A corrupt journal cannot be trusted, but the fixed backup names still
    // let startup conservatively restore code without deleting unknown data.
    deps.stop(pluginId)
    if (await exists(transactionPaths.codeBackup)) {
      await rm(transactionPaths.destination, { force: true, recursive: true })
      await rename(transactionPaths.codeBackup, transactionPaths.destination)
    }
    if (await exists(transactionPaths.dataBackup)) {
      await rm(transactionPaths.data, { force: true, recursive: true })
      await rename(transactionPaths.dataBackup, transactionPaths.data)
    }
    await rm(transactionPaths.candidate, { force: true, recursive: true })
    await rm(transactionPaths.journal, { force: true })
  }

  const withLock = async <Value>(
    pluginId: string,
    operation: () => Promise<Value>
  ): Promise<Value> => {
    paths(pluginId)
    const previous = locks.get(pluginId) ?? Promise.resolve()
    /* v8 ignore next -- the Promise constructor below replaces this synchronously. */
    let release = (): void => undefined
    const gate = new Promise<void>((resolvePromise) => {
      release = resolvePromise
    })
    const tail = previous.then(() => gate)
    locks.set(pluginId, tail)
    await previous
    try {
      return await operation()
    } finally {
      release()
      if (locks.get(pluginId) === tail) locks.delete(pluginId)
    }
  }

  const apply = async (pluginId: string, hadExisting: boolean): Promise<void> => {
    const transactionPaths = paths(pluginId)
    const hadData = await exists(transactionPaths.data)
    let journal: PluginTransactionJournal = {
      hadData,
      hadExisting,
      phase: "prepared",
      pluginId,
      schemaVersion: 1
    }
    await writeJournal(journal)
    try {
      if (hadExisting) deps.stop(pluginId)
      journal = { ...journal, phase: "stopped" }
      await writeJournal(journal)

      await rm(transactionPaths.dataBackup, { force: true, recursive: true })
      if (hadData) {
        await mkdir(dataTransactionsRoot, { recursive: true })
        await cp(transactionPaths.data, transactionPaths.dataBackup, { recursive: true })
      }
      journal = { ...journal, phase: "dataBackedUp" }
      await writeJournal(journal)

      await rm(transactionPaths.codeBackup, { force: true, recursive: true })
      journal = { ...journal, phase: "codeBackedUp" }
      await writeJournal(journal)

      // Each rename is atomic, and the synchronous pair prevents any other
      // request in this process from observing the destination between them.
      // The intent journal repairs the tiny process-crash window at startup.
      if (hadExisting) {
        renameSync(transactionPaths.destination, transactionPaths.codeBackup)
      }
      renameSync(transactionPaths.candidate, transactionPaths.destination)
      journal = { ...journal, phase: "candidateInstalled" }
      await writeJournal(journal)
      await deps.verifyInstalled(pluginId)
      journal = { ...journal, phase: "verified" }
      await writeJournal(journal)
    } catch (cause) {
      try {
        await restore(journal, true)
      } catch (rollbackCause) {
        throw new PluginsError(
          "unavailable",
          `Plugin ${pluginId} update failed (${failureMessage(cause)}) and rollback failed (${failureMessage(rollbackCause)})`
        )
      }
      throw cause
    }
    await promoteKnownGood(journal)
  }

  const recover = async (): Promise<void> => {
    let entries: ReadonlyArray<string>
    try {
      entries = await readdir(transactionsRoot)
    } catch {
      return
    }
    const pluginIds = new Set<string>()
    for (const entry of entries) {
      const journalMatch = JOURNAL_PATTERN.exec(entry)
      if (journalMatch?.[1] !== undefined) pluginIds.add(journalMatch[1])
      const artifactMatch = /^(.+)\.(?:candidate|code-backup)$/.exec(entry)
      if (artifactMatch?.[1] !== undefined && PLUGIN_ID_PATTERN.test(artifactMatch[1])) {
        pluginIds.add(artifactMatch[1])
      }
    }
    await Promise.all(
      [...pluginIds].map((pluginId) => withLock(pluginId, () => recoverPlugin(pluginId)))
    )
  }

  return { apply, paths, recover, recoverPlugin, withLock }
}
