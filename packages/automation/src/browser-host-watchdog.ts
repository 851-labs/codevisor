import type { EventEmitter } from "node:events"

export interface WatchedHostChannel extends EventEmitter {
  ended(): void
}

export const watchBrowserHostChannel = (
  channel: WatchedHostChannel,
  silenceMs: number,
  hostAnswers: () => Promise<boolean>
): void => {
  let unanswered = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  let checking = false

  const disarm = () => {
    clearTimeout(timer)
    timer = undefined
  }

  const arm = () => {
    disarm()
    if (unanswered === 0) return

    timer = setTimeout(() => void check(), silenceMs)
    timer.unref?.()
  }

  const check = async () => {
    if (checking) return

    checking = true
    const alive = await hostAnswers().catch(() => false)
    checking = false
    if (alive) arm()
    else channel.ended()
  }

  channel.on("sent", () => {
    unanswered += 1
    if (timer === undefined) arm()
  })
  channel.on("message", (data: Buffer) => {
    if (isCommandReply(data)) unanswered = Math.max(0, unanswered - 1)
    arm()
  })
  channel.on("close", disarm)
}

const isCommandReply = (data: Buffer): boolean => /^\s*\{\s*"id"\s*:/.test(data.toString())
