import { randomBytes } from "node:crypto"

import type { ChannelPeer } from "@codevisor/cloud-client"
import type { BotLink } from "@codevisor/db"

export interface TicketBook<T> {
  readonly issue: (value: T) => string
  readonly take: (ticket: string | undefined) => T | undefined
  readonly revoke: (ticket: string) => void
}

export interface VerifiedRemoteParent {
  readonly parentSessionId: string
  readonly bot?: BotLink
}

export interface FleetTickets {
  readonly callers: TicketBook<ChannelPeer>
  readonly remoteParents: TicketBook<VerifiedRemoteParent>
}

export const makeFleetTickets = (): FleetTickets => ({
  callers: makeTicketBook(),
  remoteParents: makeTicketBook()
})

export const withTicket = async <T, R>(
  book: TicketBook<T>,
  value: T,
  use: (ticket: string) => Promise<R>
): Promise<R> => {
  const ticket = book.issue(value)
  try {
    return await use(ticket)
  } finally {
    book.revoke(ticket)
  }
}

const TICKET_BYTES = 32

const makeTicketBook = <T>(): TicketBook<T> => {
  const issued = new Map<string, T>()
  return {
    issue: (value) => {
      const ticket = randomBytes(TICKET_BYTES).toString("base64url")
      issued.set(ticket, value)
      return ticket
    },
    take: (ticket) => {
      if (ticket === undefined) return undefined
      const value = issued.get(ticket)
      issued.delete(ticket)
      return value
    },
    revoke: (ticket) => {
      issued.delete(ticket)
    }
  }
}
