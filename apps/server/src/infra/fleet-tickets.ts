import { randomBytes } from "node:crypto"

import type { AgentRef } from "@codevisor/api"
import type { ChannelPeer } from "@codevisor/cloud-client"

export interface TicketBook<T> {
  readonly issue: (value: T) => string
  readonly take: (ticket: string | undefined) => T | undefined
  readonly revoke: (ticket: string) => void
}

export interface FleetTickets {
  readonly callers: TicketBook<ChannelPeer>
  readonly callerAgents: TicketBook<AgentRef>
}

export const makeFleetTickets = (): FleetTickets => ({
  callers: makeTicketBook(),
  callerAgents: makeTicketBook()
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
