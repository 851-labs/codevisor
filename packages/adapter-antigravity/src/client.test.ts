import type { NdjsonTransport } from "@codevisor/agent-runtime"
import { describe, expect, it, vi } from "vitest"

import { wireAgyProcess } from "./client.js"

const transport = () => {
  let line: ((line: string) => void) | undefined
  let failure: ((error: Error) => void) | undefined
  const sent: Array<Record<string, unknown>> = []
  const fake: NdjsonTransport = {
    pid: 1,
    isOpen: () => true,
    send: (payload) => void sent.push(payload),
    onLine: (handler) => {
      line = handler
    },
    onFailure: (handler) => {
      failure = handler
    },
    close: vi.fn()
  }
  return {
    fake,
    sent,
    line: (value: string) => line!(value),
    fail: (error: Error) => failure!(error)
  }
}

describe("agy process wiring", () => {
  it("parses agy's lines into events and skips what isn't JSON", () => {
    const pipe = transport()
    const agy = wireAgyProcess(pipe.fake, () => undefined)
    const events: Array<Record<string, unknown>> = []
    pipe.line('{"event":"init"}')
    agy.onEvent((event) => events.push(event))
    pipe.line("warning: not json")
    pipe.line('{"event":"result","result":{}}')
    pipe.line("[1,2]")
    expect(events).toEqual([{ event: "result", result: {} }, {}])
  })

  it("keeps reading after a handler throws", () => {
    const pipe = transport()
    const agy = wireAgyProcess(pipe.fake, () => undefined)
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const seen: Array<unknown> = []
    agy.onEvent((event) => {
      seen.push(event.n)
      if (event.n === 1) throw new Error("boom")
    })
    pipe.line('{"n":1}')
    pipe.line('{"n":2}')
    expect(seen).toEqual([1, 2])
    expect(logged).toHaveBeenCalledOnce()
    logged.mockRestore()
  })

  it("sends lines, interrupts, reports exits and closes the pipe", () => {
    const pipe = transport()
    const interrupt = vi.fn()
    const agy = wireAgyProcess(pipe.fake, interrupt)
    agy.send({ event: "user" })
    expect(pipe.sent).toEqual([{ event: "user" }])
    agy.interrupt()
    expect(interrupt).toHaveBeenCalledOnce()
    const exited = vi.fn()
    agy.onExit(exited)
    pipe.fail(new Error("agy exited"))
    expect(exited).toHaveBeenCalledWith(new Error("agy exited"))
    agy.close()
    expect(pipe.fake.close).toHaveBeenCalledOnce()
  })
})
