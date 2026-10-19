import { randomUUID } from "node:crypto"

export interface ClipboardRepresentation {
  readonly type: string
  readonly data: Buffer
}

export type ClipboardContent = ReadonlyArray<ReadonlyArray<ClipboardRepresentation>>

export const TEXT_TYPE = "public.utf8-plain-text"
export const MAXIMUM_CONTENT_BYTES = 32 * 1024 * 1024
export const RICH_CHUNK_BYTES = 48 * 1024
export const RICH_WINDOW = 8
const MAXIMUM_TYPE_BYTES = 256
const DEADLINE_MS = 10_000

export const archiveClipboard = (content: ClipboardContent): Buffer => {
  const parts: Buffer[] = []
  const number = (value: number) => {
    const bytes = Buffer.alloc(4)
    bytes.writeUInt32BE(value)
    parts.push(bytes)
  }
  number(content.length)
  for (const item of content) {
    number(item.length)
    for (const { type, data } of item) {
      const typeBytes = Buffer.from(type, "utf8")
      number(typeBytes.length)
      parts.push(typeBytes)
      number(data.length)
      parts.push(data)
    }
  }
  return Buffer.concat(parts)
}

export const unarchiveClipboard = (archive: Buffer): ClipboardContent | undefined => {
  let offset = 0
  const take = (count: number): Buffer => {
    if (count > archive.length - offset) throw new RangeError("The archive is truncated")
    offset += count
    return archive.subarray(offset - count, offset)
  }
  const count = (maximum = archive.length): number => {
    const value = take(4).readUInt32BE()
    if (value === 0 || value > maximum) throw new RangeError("The archive has an invalid count")
    return value
  }
  try {
    const content = Array.from({ length: count() }, () =>
      Array.from({ length: count() }, () => {
        const type = take(count(MAXIMUM_TYPE_BYTES)).toString("utf8")
        return { type, data: Buffer.from(take(take(4).readUInt32BE())) }
      })
    )
    return offset === archive.length ? content : undefined
  } catch {
    return undefined
  }
}

export const sameClipboard = (left: ClipboardContent, right: ClipboardContent): boolean =>
  archiveClipboard(left).equals(archiveClipboard(right))

export type ClipboardMessage =
  | { readonly read: { readonly id: string } }
  | {
      readonly begin: {
        readonly id: string
        readonly bytes: number
        readonly richContent?: boolean
      }
    }
  | { readonly chunk: { readonly id: string; readonly index: number; readonly data: string } }
  | { readonly ack: { readonly id: string; readonly nextIndex: number } }
  | { readonly end: { readonly id: string } }
  | { readonly result: { readonly id: string; readonly error?: string } }
  | { readonly cancel: { readonly id: string } }

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

const isCount = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0

export const parseClipboardMessage = (value: unknown): ClipboardMessage | undefined => {
  if (!isRecord(value)) return undefined
  const [entry, ...others] = Object.entries(value)
  if (entry === undefined || others.length > 0) return undefined
  const [name, fields] = entry
  if (!isRecord(fields)) return undefined
  const { id, bytes, richContent, index, data, nextIndex, error } = fields
  if (typeof id !== "string" || id === "" || id.length > 64) return undefined
  switch (name) {
    case "read":
      return { read: { id } }
    case "end":
      return { end: { id } }
    case "cancel":
      return { cancel: { id } }
    case "begin":
      return isCount(bytes) && (richContent === undefined || typeof richContent === "boolean")
        ? { begin: { id, bytes, ...(richContent === true ? { richContent } : {}) } }
        : undefined
    case "chunk":
      return isCount(index) && typeof data === "string" ? { chunk: { id, index, data } } : undefined
    case "ack":
      return isCount(nextIndex) ? { ack: { id, nextIndex } } : undefined
    case "result":
      if (error === undefined) return { result: { id } }
      return typeof error === "string" ? { result: { id, error } } : undefined
    default:
      return undefined
  }
}

const errorText = (error: unknown): string =>
  (error instanceof Error ? error.message : String(error)).slice(0, 256)

export interface ClipboardTransferOptions {
  readonly send: (message: ClipboardMessage) => boolean
  readonly now: () => number
  readonly canReceiveUnsolicited: () => boolean
  readonly read: () => Promise<ClipboardContent>
  readonly write: (content: ClipboardContent) => Promise<void>
  readonly onFinished: (error: string | undefined) => void
}

interface Outgoing {
  readonly id: string
  readonly data: Buffer
  readonly chunks: number
  sent: number
  acknowledged: number
  awaitingEnd: boolean
}

interface Incoming {
  readonly id: string
  readonly count: number
  readonly parts: Buffer[]
  received: number
  nextIndex: number
}

export class ClipboardTransfer {
  private outgoing: Outgoing | undefined
  private incoming: Incoming | undefined
  private pending: string | undefined
  private deadline = 0

  constructor(private readonly options: ClipboardTransferOptions) {}

  get busy(): boolean {
    return this.outgoing !== undefined || this.incoming !== undefined || this.pending !== undefined
  }

  get sending(): boolean {
    return this.outgoing !== undefined
  }

  sendContent(content: ClipboardContent): void {
    if (!this.busy) this.start(content, randomUUID().toUpperCase())
  }

  tick(): void {
    if (this.busy && this.options.now() >= this.deadline)
      this.cancel("Clipboard transfer timed out. Try again.")
  }

  cancel(reason?: string): void {
    const id = this.outgoing?.id ?? this.incoming?.id ?? this.pending
    if (id === undefined) return
    this.finish(reason)
    this.options.send({ cancel: { id } })
  }

  receive(message: ClipboardMessage): void {
    this.tick()
    if ("read" in message) {
      const { id } = message.read
      if (this.busy) {
        this.reject(id, "Clipboard is unavailable or busy.")
        return
      }
      this.pending = id
      this.extendDeadline()
      this.options.read().then(
        (content) => {
          if (this.pending !== id) return
          this.pending = undefined
          this.start(content, id)
        },
        (error: unknown) => {
          if (this.pending !== id) return
          this.pending = undefined
          this.reject(id, errorText(error))
        }
      )
    } else if ("begin" in message) {
      const { id, bytes, richContent } = message.begin
      if (
        this.busy ||
        !this.options.canReceiveUnsolicited() ||
        richContent !== true ||
        bytes > MAXIMUM_CONTENT_BYTES
      ) {
        this.reject(id, "Clipboard transfer was not requested or is too large.")
        return
      }
      this.incoming = { id, count: bytes, parts: [], received: 0, nextIndex: 0 }
      this.extendDeadline()
      this.transmit({ ack: { id, nextIndex: 0 } })
    } else if ("chunk" in message) {
      const current = this.incoming
      const { id, index } = message.chunk
      if (current?.id !== id) return
      const data = Buffer.from(message.chunk.data, "base64")
      if (
        index !== current.nextIndex ||
        data.length === 0 ||
        data.length > RICH_CHUNK_BYTES ||
        current.received + data.length > current.count
      ) {
        this.rejectCurrent(id, "Invalid clipboard chunk.")
        return
      }
      current.parts.push(data)
      current.received += data.length
      current.nextIndex += 1
      this.extendDeadline()
      this.transmit({ ack: { id, nextIndex: current.nextIndex } })
    } else if ("ack" in message) {
      const current = this.outgoing
      const { id, nextIndex } = message.ack
      if (current?.id !== id || current.awaitingEnd) return
      if (nextIndex !== current.acknowledged || nextIndex > current.sent) {
        this.cancel("Invalid clipboard acknowledgment.")
        return
      }
      current.acknowledged += 1
      this.extendDeadline()
      if (nextIndex === current.chunks) {
        current.awaitingEnd = true
        this.transmit({ end: { id } })
        return
      }
      while (current.sent < current.chunks && current.sent - nextIndex < RICH_WINDOW) {
        const offset = current.sent * RICH_CHUNK_BYTES
        const data = current.data.subarray(offset, offset + RICH_CHUNK_BYTES).toString("base64")
        const index = current.sent
        current.sent += 1
        if (!this.transmit({ chunk: { id, index, data } })) return
      }
    } else if ("end" in message) {
      const current = this.incoming
      const { id } = message.end
      if (current?.id !== id) return
      if (!this.options.canReceiveUnsolicited()) {
        this.rejectCurrent(id, "Clipboard transfer is no longer authorized.")
        return
      }
      const data = Buffer.concat(current.parts)
      const content = data.length === current.count ? unarchiveClipboard(data) : undefined
      if (content === undefined) {
        this.rejectCurrent(id, "Clipboard data was incomplete or not valid.")
        return
      }
      this.incoming = undefined
      this.pending = id
      this.options.write(content).then(
        () => {
          if (this.pending !== id) return
          this.options.send({ result: { id } })
          this.finish(undefined)
        },
        (error: unknown) => {
          if (this.pending === id) this.rejectCurrent(id, errorText(error))
        }
      )
    } else if ("result" in message) {
      const { id, error } = message.result
      if (this.outgoing?.id !== id) return
      if (error === undefined && !this.outgoing.awaitingEnd) {
        this.cancel("Invalid clipboard completion.")
        return
      }
      this.finish(error)
    } else {
      const { id } = message.cancel
      if (this.outgoing?.id === id || this.incoming?.id === id || this.pending === id)
        this.finish("Clipboard transfer was cancelled.")
    }
  }

  private start(content: ClipboardContent, id: string): void {
    const data = archiveClipboard(content)
    if (data.length > MAXIMUM_CONTENT_BYTES) {
      this.reject(id, "The clipboard must be 32 MB or smaller.")
      this.options.onFinished("The clipboard must be 32 MB or smaller.")
      return
    }
    this.outgoing = {
      id,
      data,
      chunks: Math.ceil(data.length / RICH_CHUNK_BYTES),
      sent: 0,
      acknowledged: 0,
      awaitingEnd: false
    }
    this.extendDeadline()
    this.transmit({ begin: { id, bytes: data.length, richContent: true } })
  }

  private extendDeadline(): void {
    this.deadline = this.options.now() + DEADLINE_MS
  }

  private transmit(message: ClipboardMessage): boolean {
    if (this.options.send(message)) return true
    this.finish("The clipboard channel is unavailable. Reconnect and try again.")
    return false
  }

  private reject(id: string, error: string): void {
    this.options.send({ result: { id, error: error.slice(0, 256) } })
  }

  private rejectCurrent(id: string, error: string): void {
    this.finish(error)
    this.reject(id, error)
  }

  private finish(error: string | undefined): void {
    this.outgoing = undefined
    this.incoming = undefined
    this.pending = undefined
    this.options.onFinished(error)
  }
}
