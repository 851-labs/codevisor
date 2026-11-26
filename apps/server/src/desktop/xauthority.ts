import { randomBytes } from "node:crypto"

const familyWild = 0xffff
const cookieName = "MIT-MAGIC-COOKIE-1"
const cookieBytes = 16

export const xauthorityEntry = (cookie: Buffer = randomBytes(cookieBytes)): Buffer =>
  Buffer.concat([
    uint16(familyWild),
    counted(Buffer.alloc(0)),
    counted(Buffer.alloc(0)),
    counted(Buffer.from(cookieName, "latin1")),
    counted(cookie)
  ])

const uint16 = (value: number): Buffer => {
  const bytes = Buffer.alloc(2)
  bytes.writeUInt16BE(value)
  return bytes
}

const counted = (bytes: Buffer): Buffer => Buffer.concat([uint16(bytes.length), bytes])
