import type { RuntimeEvent } from "@codevisor/agent-runtime"

import { record } from "./internal.js"
import type { OpenCodeServer } from "./server.js"

export interface RecordedRequest {
  readonly path: string
  readonly method: string
  readonly body: Record<string, unknown> | undefined
  readonly location: string | undefined
}

type RequestInit = Parameters<OpenCodeServer["request"]>[1]

const waiters = <T>() => {
  const seen: Array<T> = []
  const pending = new Set<{
    readonly match: (value: T) => boolean
    readonly resolve: (value: T) => void
  }>()
  return {
    seen,
    add: (value: T) => {
      seen.push(value)
      for (const waiter of pending) {
        if (!waiter.match(value)) continue
        pending.delete(waiter)
        waiter.resolve(value)
      }
    },
    next: (match: (value: T) => boolean, from = 0): Promise<T> => {
      const found = seen.slice(from).find(match)
      if (found !== undefined) return Promise.resolve(found)
      return new Promise((resolve) => pending.add({ match, resolve }))
    }
  }
}

export const makeEventQueue = () => {
  const buffered: Array<IteratorResult<unknown>> = []
  let failure: Error | undefined
  let waiting:
    | {
        readonly resolve: (result: IteratorResult<unknown>) => void
        readonly reject: (cause: Error) => void
      }
    | undefined
  let returned = 0
  const settle = (result: IteratorResult<unknown> | Error) => {
    const current = waiting
    if (current === undefined) {
      if (result instanceof Error) failure = result
      else buffered.push(result)
      return
    }
    waiting = undefined
    if (result instanceof Error) current.reject(result)
    else current.resolve(result)
  }
  const iterator: AsyncIterator<unknown> = {
    next: () => {
      const result = buffered.shift()
      if (result !== undefined) return Promise.resolve(result)
      if (failure !== undefined) return Promise.reject(failure)
      return new Promise((resolve, reject) => {
        waiting = { resolve, reject }
      })
    },
    return: async () => {
      returned += 1
      return { done: true, value: undefined }
    }
  }
  return {
    iterator,
    push: (...events: ReadonlyArray<unknown>) => {
      for (const value of events) settle({ done: false, value })
    },
    end: () => settle({ done: true, value: undefined }),
    fail: (cause: Error) => settle(cause),
    returned: () => returned
  }
}

export const makeFakeServer = (
  respond: (request: RecordedRequest) => unknown = () => undefined,
  queue = makeEventQueue()
) => {
  const requests = waiters<RecordedRequest>()
  const subscriptions: Array<AbortSignal> = []
  let stopped = 0
  const server: OpenCodeServer = {
    url: "http://opencode.test",
    request: async (path: string, init: RequestInit = {}) => {
      const request: RecordedRequest = {
        path,
        method: init.method ?? (init.body === undefined ? "GET" : "POST"),
        body: record(init.body),
        location: init.location
      }
      requests.add(request)
      return respond(request)
    },
    subscribe: (signal) => {
      subscriptions.push(signal)
      signal.addEventListener("abort", () => queue.fail(new Error("aborted")), { once: true })
      return { [Symbol.asyncIterator]: () => queue.iterator }
    },
    stop: async () => {
      stopped += 1
    }
  }
  return {
    server,
    queue,
    requests: requests.seen,
    requested: (match: (request: RecordedRequest) => boolean, from?: number) =>
      requests.next(match, from),
    subscriptions,
    stopped: () => stopped
  }
}

export const makeSink = () => {
  const events = waiters<RuntimeEvent>()
  return {
    events: events.seen,
    emit: async (event: RuntimeEvent) => events.add(event),
    emitted: (match: (event: RuntimeEvent) => boolean, from?: number) => events.next(match, from),
    updates: (kind: string) =>
      events.seen.flatMap((event) => {
        const payload = record(event.payload) ?? {}
        return payload.sessionUpdate === kind ? [payload] : []
      })
  }
}

export const payload = (event: RuntimeEvent): Record<string, unknown> => record(event.payload) ?? {}

export const event = (type: string, data: Record<string, unknown>) => ({ type, data })

export const firstQuestion = (asked: Record<string, unknown>): unknown =>
  Array.isArray(asked.questions) ? record(asked.questions[0])?.question : undefined
