import { endianness } from "node:os"

export const HOST_TO_BROWSER_CHUNK_CHARACTERS = 128 * 1024

const HEADER_BYTES = 4
const littleEndian = endianness() === "LE"

export const encodeNativeMessage = (value) => {
  const body = Buffer.from(JSON.stringify(value), "utf8")
  const header = Buffer.alloc(HEADER_BYTES)
  if (littleEndian) header.writeUInt32LE(body.length)
  else header.writeUInt32BE(body.length)
  return Buffer.concat([header, body])
}

export const makeNativeMessageReader = (onMessage) => {
  const parts = []
  let buffered = 0
  const take = (byteCount) => {
    const joined = Buffer.concat(parts, buffered)
    parts.splice(0, parts.length, joined.subarray(byteCount))
    buffered -= byteCount
    return joined.subarray(0, byteCount)
  }
  return (data) => {
    parts.push(data)
    buffered += data.length
    for (;;) {
      if (buffered < HEADER_BYTES) return
      const length = bodyLength(Buffer.concat(parts, HEADER_BYTES))
      if (buffered < HEADER_BYTES + length) return
      take(HEADER_BYTES)
      onMessage(JSON.parse(take(length).toString("utf8")))
    }
  }
}

export const frameMessages = (text, chunkCharacters, nextId) => {
  if (text.length <= chunkCharacters) return [text]
  const id = nextId()
  const count = Math.ceil(text.length / chunkCharacters)
  return Array.from({ length: count }, (_, index) => ({
    type: "chunk",
    id,
    index,
    count,
    data: text.slice(index * chunkCharacters, (index + 1) * chunkCharacters)
  }))
}

export const makeFrameAssembler = () => {
  const pending = new Map()
  return (message) => {
    if (typeof message === "string") return message
    if (message?.type !== "chunk") return undefined
    const parts = pending.get(message.id) ?? []
    parts[message.index] = message.data
    if (message.index < message.count - 1) {
      pending.set(message.id, parts)
      return undefined
    }
    pending.delete(message.id)
    return parts.join("")
  }
}

const bodyLength = (header) => (littleEndian ? header.readUInt32LE(0) : header.readUInt32BE(0))
