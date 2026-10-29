import type { RoleFenceToken } from "@codevisor/api"

import type { CancelTimeout } from "./machine-socket.js"

export const ROLE_CLOCK_MARGIN_MS = 2_000

export interface HeldRole {
  readonly role: string
  readonly version: number
  readonly signal: AbortSignal
  readonly fence: RoleFenceToken
  readonly held: () => boolean
}

export type RoleTask = (lease: HeldRole) => void | Promise<void>

export interface RoleClock {
  readonly now: () => number
  readonly scheduleTimeout: (callback: () => void, delayMs: number) => CancelTimeout
}

export class LocalRoleLease {
  readonly #controller = new AbortController()
  #deadline: number
  #cancelExpiry: CancelTimeout | undefined
  #cancelRenewal: CancelTimeout | undefined

  constructor(
    readonly role: string,
    readonly version: number,
    deadline: number,
    private readonly clock: RoleClock,
    private readonly onExpired: () => void
  ) {
    this.#deadline = deadline
    this.#armExpiry()
  }

  get signal(): AbortSignal {
    return this.#controller.signal
  }

  extend(deadline: number): void {
    this.#deadline = deadline
    this.#armExpiry()
  }

  renewAt(time: number, renew: () => void): void {
    this.#cancelRenewal?.()
    this.#cancelRenewal = this.clock.scheduleTimeout(renew, Math.max(0, time - this.clock.now()))
  }

  held(): boolean {
    return !this.signal.aborted && this.clock.now() < this.#deadline
  }

  view(): HeldRole {
    return {
      role: this.role,
      version: this.version,
      signal: this.signal,
      fence: { role: this.role, version: this.version },
      held: () => this.held()
    }
  }

  end(): void {
    this.#cancelExpiry?.()
    this.#cancelRenewal?.()
    this.#controller.abort(new Error(`No longer holding the ${this.role} role`))
  }

  #armExpiry(): void {
    this.#cancelExpiry?.()
    this.#cancelExpiry = this.clock.scheduleTimeout(
      this.onExpired,
      Math.max(0, this.#deadline - this.clock.now())
    )
  }
}

export const localDeadline = (sentAt: number, leaseMs: number): number =>
  sentAt + leaseMs - ROLE_CLOCK_MARGIN_MS
