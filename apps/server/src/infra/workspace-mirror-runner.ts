import type { MirrorSourceHead, WorkspaceMirrorState, WorkspaceMirrorStatus } from "@codevisor/api"

import type { PreparedMirror } from "./mirror-store.js"
import {
  changedFileCount,
  commitSnapshot,
  ensureSnapshotRepo,
  hasCommit,
  packSince,
  takeSnapshot,
  type SnapshotRepo
} from "./workspace-snapshot.js"
import { shareSourceObjects, sourceCheckout } from "./workspace-source-head.js"

export interface MirrorTransport {
  readonly prepare: (machineId: string, mirrorId: string, name: string) => Promise<PreparedMirror>
  readonly write: (
    machineId: string,
    mirrorId: string,
    offset: number,
    data: Buffer
  ) => Promise<void>
  readonly apply: (
    machineId: string,
    mirrorId: string,
    commit: string,
    head: MirrorSourceHead | undefined
  ) => Promise<PreparedMirror>
  readonly remove: (machineId: string, mirrorId: string) => Promise<void>
}

export interface WorkspaceMirrorRecord {
  readonly workspaceId: string
  readonly workspaceName: string
  readonly root: string
  readonly machineId: string
  readonly machineName: string
  readonly mirrorId: string
}

export interface MirrorRunnerOptions {
  readonly record: WorkspaceMirrorRecord
  readonly repo: SnapshotRepo
  readonly transport: MirrorTransport
  readonly intervalMs: number
  readonly retryMs: number
  readonly now: () => Date
}

interface LastSync {
  readonly files: number
  readonly bytes: number
  readonly ms: number
}

interface PassWaiter {
  readonly after: number
  readonly resolve: () => void
}

export const MIRROR_CHUNK_BYTES = 4 * 1024 * 1024

export class MirrorRunner {
  private state: WorkspaceMirrorState = "syncing"
  private path: string | undefined
  private targetHead: string | undefined
  private targetSourceHead: string | undefined
  private lastTree: string | undefined
  private lastHead: string | undefined
  private lastSyncedAt: string | undefined
  private lastSync: LastSync | undefined
  private error: string | undefined
  private skipped: ReadonlyArray<string> = []
  private timer: ReturnType<typeof setTimeout> | undefined
  private passing: Promise<void> | undefined
  private passes = 0
  private waiters: PassWaiter[] = []
  private stopped = false
  private repoLock: Promise<unknown> = Promise.resolve()

  constructor(private readonly options: MirrorRunnerOptions) {}

  get record(): WorkspaceMirrorRecord {
    return this.options.record
  }

  start(): void {
    this.schedule(0)
  }

  async stop(): Promise<void> {
    this.stopped = true
    if (this.timer !== undefined) clearTimeout(this.timer)
    for (const waiter of this.waiters) waiter.resolve()
    this.waiters = []
    await this.repoLock
  }

  nextPass(): Promise<void> {
    if (this.stopped) return Promise.resolve()
    const waiting = new Promise<void>((resolve) => {
      this.waiters.push({ after: this.passes, resolve })
    })
    if (this.passing === undefined) this.schedule(0)
    return waiting
  }

  async status(): Promise<WorkspaceMirrorStatus> {
    const { record } = this.options
    return {
      workspaceId: record.workspaceId,
      machine: { machineId: record.machineId, name: record.machineName },
      ...(this.path === undefined ? {} : { path: this.path }),
      state: this.state,
      pendingChanges: await this.hasPendingChanges(),
      ...(this.lastSyncedAt === undefined ? {} : { lastSyncedAt: this.lastSyncedAt }),
      ...(this.lastSync === undefined ? {} : { lastSync: this.lastSync }),
      skipped: [...this.skipped],
      ...(this.error === undefined ? {} : { error: this.error })
    }
  }

  private async hasPendingChanges(): Promise<boolean> {
    if (this.lastTree === undefined || this.passing !== undefined) return true
    const snapshot = await this.withRepo(() => takeSnapshot(this.options.repo)).catch(
      () => undefined
    )
    return snapshot === undefined || snapshot.tree !== this.lastTree
  }

  private withRepo<T>(work: () => Promise<T>): Promise<T> {
    const next = this.repoLock.then(work, work)
    this.repoLock = next.catch(() => undefined)
    return next
  }

  private schedule(delayMs: number): void {
    if (this.stopped) return
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = setTimeout(() => void this.tick(), delayMs)
    this.timer.unref?.()
  }

  private async tick(): Promise<void> {
    if (this.stopped || this.passing !== undefined) return
    this.passes += 1
    const pass = this.passes
    this.passing = this.withRepo(() => this.pass())
    await this.passing
    this.passing = undefined
    this.settleWaiters(pass)
    const pending = this.waiters.length > 0
    this.schedule(this.nextDelay(pending))
  }

  private nextDelay(pending: boolean): number {
    if (pending) return 0
    return this.state === "failed" ? this.options.retryMs : this.options.intervalMs
  }

  private settleWaiters(pass: number): void {
    const done = this.waiters.filter((waiter) => waiter.after < pass)
    this.waiters = this.waiters.filter((waiter) => waiter.after >= pass)
    for (const waiter of done) waiter.resolve()
  }

  private async pass(): Promise<void> {
    try {
      await this.syncOnce()
      this.state = "synced"
      this.error = undefined
    } catch (cause) {
      this.state = "failed"
      this.error = cause instanceof Error ? cause.message : String(cause)
      this.targetHead = undefined
      this.targetSourceHead = undefined
    }
  }

  private async syncOnce(): Promise<void> {
    const { repo } = this.options
    await ensureSnapshotRepo(repo)
    const checkout = await sourceCheckout(this.options.record.root)
    if (checkout !== undefined) await shareSourceObjects(repo, checkout.objects)
    const snapshot = await takeSnapshot(repo)
    this.skipped = snapshot.skipped
    if (this.targetHead === undefined) await this.prepareTarget()
    const unchanged = snapshot.tree === this.lastTree && headKey(checkout?.head) === this.lastHead
    if (unchanged && this.targetHead !== undefined) return

    this.state = "syncing"
    await this.push(snapshot.tree, checkout?.head)
  }

  private async prepareTarget(): Promise<void> {
    const { record, transport } = this.options
    const prepared = await transport.prepare(
      record.machineId,
      record.mirrorId,
      record.workspaceName
    )
    this.path = prepared.path
    this.targetHead = prepared.head
    this.targetSourceHead = prepared.sourceHead
    this.lastTree = undefined
  }

  private async push(tree: string, head: MirrorSourceHead | undefined): Promise<void> {
    const { record, repo, transport } = this.options
    const started = this.options.now().getTime()
    const base = await this.usable(this.targetHead)
    const commit = await commitSnapshot(repo, tree, base)
    const baseHead = await this.usable(this.targetSourceHead)
    const pack = await packSince(repo, { commit, base, head: head?.commit, baseHead })
    await this.upload(pack)
    const applied = await transport.apply(record.machineId, record.mirrorId, commit, head)
    this.path = applied.path
    this.targetHead = commit
    this.targetSourceHead = head?.commit
    this.lastTree = tree
    this.lastHead = headKey(head)
    this.lastSyncedAt = this.options.now().toISOString()
    this.lastSync = {
      files: await changedFileCount(repo, base, commit),
      bytes: pack.length,
      ms: this.options.now().getTime() - started
    }
  }

  private async usable(commit: string | undefined): Promise<string | undefined> {
    if (commit === undefined) return undefined
    return (await hasCommit(this.options.repo, commit)) ? commit : undefined
  }

  private async upload(pack: Buffer): Promise<void> {
    const { record, transport } = this.options
    for (let offset = 0; offset < pack.length; offset += MIRROR_CHUNK_BYTES) {
      const chunk = pack.subarray(offset, offset + MIRROR_CHUNK_BYTES)
      await transport.write(record.machineId, record.mirrorId, offset, chunk)
    }
  }
}

const headKey = (head: MirrorSourceHead | undefined): string | undefined =>
  head === undefined ? undefined : `${head.commit} ${head.branch ?? ""}`
