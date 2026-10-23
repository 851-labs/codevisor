import type { MachineCallOrigin } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import type { MachineLink } from "../infra/machine-link.js"
import { forwardSessionEvent } from "./fleet-session-events.js"
import { turnEndedMessage } from "./session-event-messages.js"

interface SentEvent {
  readonly machine: string
  readonly path: string
  readonly args: unknown
  readonly origin: MachineCallOrigin
}

const recordingLink = (current: ReadonlyArray<{ readonly name: string }>) => {
  const sent: SentEvent[] = []
  const link: MachineLink = {
    list: async () =>
      current.map((machine) => ({
        id: "machine-laptop",
        name: machine.name,
        online: true,
        isCurrent: true
      })),
    resolve: () => undefined,
    machineIdOf: () => undefined,
    invoke: async (machine, path, args, origin) => {
      sent.push({ machine, path, args, origin })
      return null
    }
  }
  return { link, sent }
}

const child = { id: "child-1", title: "Fix the laptop" } as const
const subscriber = {
  subscriber: { machineId: "machine-studio", sessionId: "bot-session" },
  bot: { botId: "bot-1", botMachineId: "machine-studio" }
}
const message = turnEndedMessage(child, "end_turn", "done")

describe("forwarding session events to another machine", () => {
  it("sends the event to the subscriber's machine, attributed to this one", async () => {
    const { link, sent } = recordingLink([{ name: "Laptop" }])

    await forwardSessionEvent(link, "machine-laptop", child, subscriber, message)

    expect(sent).toEqual([
      {
        machine: "machine-studio",
        path: "fleet.session_event",
        args: {
          sessionId: "bot-session",
          botId: "bot-1",
          key: "turn_ended:child-1",
          text: message.text.replace(
            "<codevisor-event ",
            '<codevisor-event machine="Laptop" machineId="machine-laptop" '
          )
        },
        origin: {
          machineId: "machine-laptop",
          machineName: "Laptop",
          sessionId: "child-1",
          sessionTitle: "Fix the laptop"
        }
      }
    ])
  })

  it("names this machine by its id when the link doesn't list it, and skips without a link", async () => {
    const { link, sent } = recordingLink([])

    await forwardSessionEvent(link, "machine-laptop", child, subscriber, message)
    await forwardSessionEvent(undefined, "machine-laptop", child, subscriber, message)

    expect(sent.map((event) => event.origin.machineName)).toEqual(["machine-laptop"])
  })
})
