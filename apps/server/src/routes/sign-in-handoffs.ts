export type SignInHandoff = { readonly authorizationUrl: string } | { readonly failure: string }

export interface SignInHandoffs {
  readonly settle: (ticket: string | undefined, handoff: SignInHandoff) => void
  readonly wait: (ticket: string) => Promise<SignInHandoff>
}

export interface SignInHandoffOptions {
  readonly waitMs?: number
  readonly sleep?: (ms: number) => Promise<void>
}

export const ticketParameter = "ticket"

export const crossDeviceParameter = "crossDevice"

export const startedOnAnotherDevice = (url: URL): boolean =>
  url.searchParams.get(crossDeviceParameter) === "1"

export const signInTicket = (value: string | null | undefined): string | undefined =>
  value && ticketPattern.test(value) ? value : undefined

export const makeSignInHandoffs = (options: SignInHandoffOptions = {}): SignInHandoffs => {
  const waitMs = options.waitMs ?? defaultWaitMs
  const sleep = options.sleep ?? unrefSleep
  const pending = new Map<string, Pending>()

  const pendingFor = (ticket: string): Pending => {
    const existing = pending.get(ticket)
    if (existing !== undefined) return existing

    const created = newPending()
    pending.set(ticket, created)
    forgetOldest(pending)
    void sleep(waitMs).then(() => {
      created.settle({ failure: timedOutMessage })
      if (pending.get(ticket) === created) pending.delete(ticket)
    })
    return created
  }

  return {
    settle: (ticket, handoff) => {
      if (ticket !== undefined) pendingFor(ticket).settle(handoff)
    },
    wait: (ticket) => pendingFor(ticket).handoff
  }
}

interface Pending {
  readonly handoff: Promise<SignInHandoff>
  readonly settle: (handoff: SignInHandoff) => void
}

const newPending = (): Pending => {
  const { promise, resolve } = Promise.withResolvers<SignInHandoff>()
  return { handoff: promise, settle: resolve }
}

const forgetOldest = (pending: Map<string, Pending>): void => {
  for (const [ticket, oldest] of pending) {
    if (pending.size <= maxPending) return
    oldest.settle({ failure: timedOutMessage })
    pending.delete(ticket)
  }
}

const unrefSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms).unref()
  })

const ticketPattern = /^[A-Za-z0-9-]{16,64}$/

const defaultWaitMs = 90_000

const maxPending = 64

const timedOutMessage = "Sign-in took too long to start. Try again from Codevisor."
