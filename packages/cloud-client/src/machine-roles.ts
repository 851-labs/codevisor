import {
  ROLE_RENEW_MS,
  type HubRoleHolders,
  type HubRoleLease,
  type MachineToHub,
  type RoleAvailability,
  type RoleHolderView
} from "@codevisor/api"

import {
  localDeadline,
  LocalRoleLease,
  type HeldRole,
  type RoleClock,
  type RoleTask
} from "./machine-role-lease.js"

export type { HeldRole, RoleTask } from "./machine-role-lease.js"

export interface RoleView {
  readonly role: string
  readonly version: number
  readonly holder?: string
  readonly held: boolean
}

export interface MachineRoleLink {
  readonly deviceId: string
  readonly availability: RoleAvailability
  readonly send: (frame: MachineToHub) => boolean
}

export type RoleListener = (view: RoleView) => void

export interface MachineRolesOptions extends RoleClock {
  readonly log?: (line: string) => void
}

export const roleAvailabilityForIcon = (icon: string | undefined): RoleAvailability =>
  icon === "laptopcomputer" ? "portable" : "always-on"

export class MachineRoles {
  readonly #entries = new Map<string, RoleEntry>()
  #link: MachineRoleLink | undefined
  #seq = 0

  constructor(private readonly options: MachineRolesOptions) {}

  run(role: string, task: RoleTask): () => void {
    const entry = this.#entry(role)
    entry.tasks.add(task)
    this.#sendMembership()
    if (entry.lease !== undefined) startTask(task, entry.lease.view(), this.#log)
    else this.#claimIfHolder(entry)
    return () => this.#stopRunning(entry, task)
  }

  watch(role: string, listener: RoleListener): () => void {
    const entry = this.#entry(role)
    entry.listeners.add(listener)
    this.#sendMembership()
    return () => {
      entry.listeners.delete(listener)
      this.#sendMembership()
    }
  }

  holding(role: string): HeldRole | undefined {
    const lease = this.#entries.get(role)?.lease
    return lease?.held() === true ? lease.view() : undefined
  }

  views(): RoleView[] {
    return [...this.#entries.values()].map(viewOf)
  }

  attach(link: MachineRoleLink): void {
    this.#link = link
    this.#sendMembership()
    for (const entry of this.#entries.values()) {
      if (entry.lease !== undefined) this.#renew(entry, entry.lease.version)
    }
  }

  detach(): void {
    this.#link = undefined
    for (const entry of this.#entries.values()) entry.pending.clear()
  }

  receive(frame: HubRoleHolders | HubRoleLease): void {
    if (frame.t === "role-lease") return this.#onLease(frame)
    for (const view of frame.roles) this.#onHolder(view)
  }

  #onHolder(view: RoleHolderView): void {
    const entry = this.#entries.get(view.role)
    if (entry === undefined) return

    entry.view = view
    if (entry.lease !== undefined && !this.#holds(entry, view)) this.#lose(entry)
    this.#claimIfHolder(entry)
    this.#notify(entry)
  }

  #onLease(frame: HubRoleLease): void {
    const entry = this.#entries.get(frame.role)
    if (entry === undefined) return
    if (!frame.held) return this.#onRefused(entry, frame.version)

    const sentAt = takePending(entry, frame.seq)
    if (sentAt === undefined || entry.tasks.size === 0) return
    this.#confirm(entry, frame.version, localDeadline(sentAt, frame.leaseMs))
    entry.lease!.renewAt(sentAt + ROLE_RENEW_MS, () => this.#renew(entry, frame.version))
  }

  #onRefused(entry: RoleEntry, version: number): void {
    if (entry.lease?.version === version) this.#lose(entry)
    this.#send({ t: "role-release", role: entry.role, version })
  }

  #confirm(entry: RoleEntry, version: number, deadline: number): void {
    if (entry.lease?.version === version) return entry.lease.extend(deadline)

    const lease = new LocalRoleLease(entry.role, version, deadline, this.options, () =>
      this.#lose(entry)
    )
    entry.lease = lease
    for (const task of entry.tasks) startTask(task, lease.view(), this.#log)
    this.#notify(entry)
  }

  #claimIfHolder(entry: RoleEntry): void {
    const view = entry.view
    if (view === undefined || entry.tasks.size === 0 || entry.lease !== undefined) return
    if (view.holder !== this.#link?.deviceId) return

    this.#renew(entry, view.version)
  }

  #holds(entry: RoleEntry, view: RoleHolderView): boolean {
    return view.holder === this.#link?.deviceId && entry.lease?.version === view.version
  }

  #renew(entry: RoleEntry, version: number): void {
    const seq = ++this.#seq
    const sentAt = this.options.now()
    if (this.#send({ t: "role-renew", role: entry.role, version, seq })) {
      entry.pending.set(seq, sentAt)
    }
  }

  #lose(entry: RoleEntry): void {
    entry.lease?.end()
    entry.lease = undefined
    this.#notify(entry)
  }

  #stopRunning(entry: RoleEntry, task: RoleTask): void {
    entry.tasks.delete(task)
    if (entry.tasks.size > 0) return

    const lease = entry.lease
    this.#sendMembership()
    if (lease === undefined) return
    this.#lose(entry)
    this.#send({ t: "role-release", role: entry.role, version: lease.version })
  }

  #sendMembership(): void {
    const link = this.#link
    if (link === undefined) return

    const entries = [...this.#entries.values()]
    this.#send({
      t: "role-members",
      availability: link.availability,
      candidate: entries.filter(isCandidate).map(roleOf),
      watch: entries.filter((entry) => !isCandidate(entry) && entry.listeners.size > 0).map(roleOf)
    })
  }

  #send(frame: MachineToHub): boolean {
    return this.#link?.send(frame) ?? false
  }

  #notify(entry: RoleEntry): void {
    const view = viewOf(entry)
    for (const listener of entry.listeners) listener(view)
  }

  #entry(role: string): RoleEntry {
    const existing = this.#entries.get(role)
    if (existing !== undefined) return existing

    const created: RoleEntry = { role, tasks: new Set(), listeners: new Set(), pending: new Map() }
    this.#entries.set(role, created)
    return created
  }

  readonly #log = (line: string): void => this.options.log?.(line)
}

interface RoleEntry {
  readonly role: string
  readonly tasks: Set<RoleTask>
  readonly listeners: Set<RoleListener>
  readonly pending: Map<number, number>
  view?: RoleHolderView
  lease?: LocalRoleLease | undefined
}

const viewOf = (entry: RoleEntry): RoleView => ({
  role: entry.role,
  version: entry.view?.version ?? 0,
  ...(entry.view?.holder === undefined ? {} : { holder: entry.view.holder }),
  held: entry.lease?.held() === true
})

const isCandidate = (entry: RoleEntry): boolean => entry.tasks.size > 0

const roleOf = (entry: RoleEntry): string => entry.role

const takePending = (entry: RoleEntry, seq: number | undefined): number | undefined => {
  if (seq === undefined) return undefined
  const sentAt = entry.pending.get(seq)
  entry.pending.delete(seq)
  return sentAt
}

const startTask = (task: RoleTask, lease: HeldRole, log: (line: string) => void): void => {
  void (async () => task(lease))().catch((cause: unknown) => {
    log(`Role ${lease.role} task failed: ${String(cause)}`)
  })
}
