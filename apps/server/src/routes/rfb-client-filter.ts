export type RFBClientMessageKind = "input" | "clipboard" | "resize" | "other"

export class RFBClientStreamFilter {
  private buffer: Buffer = Buffer.alloc(0)
  private phase:
    | "version"
    | "security"
    | "authentication"
    | "clientInit"
    | "messages"
    | "passthrough" = "version"
  private unit: Buffer = Buffer.alloc(0)

  push(chunk: Buffer, allow: (kind: RFBClientMessageKind) => boolean): Buffer {
    const out: Buffer[] = []
    let data = chunk
    while (data.length > 0 && this.phase !== "messages" && this.phase !== "passthrough") {
      const size = this.phase === "version" ? 12 : this.phase === "authentication" ? 16 : 1
      const take = data.subarray(0, size - this.unit.length)
      out.push(take)
      this.unit = Buffer.concat([this.unit, take])
      data = data.subarray(take.length)
      if (this.unit.length === size) this.advance()
    }
    if (this.phase === "passthrough") {
      out.push(this.buffer, data)
      this.buffer = Buffer.alloc(0)
      return Buffer.concat(out)
    }
    if (data.length === 0) return Buffer.concat(out)
    this.buffer = this.buffer.length === 0 ? data : Buffer.concat([this.buffer, data])
    for (;;) {
      const next = this.message()
      if (next === undefined) break
      const [length, kind] = next
      if (kind === "passthrough") {
        out.push(this.buffer)
        this.buffer = Buffer.alloc(0)
        break
      }
      const message = this.buffer.subarray(0, length)
      this.buffer = this.buffer.subarray(length)
      if (allow(kind)) out.push(message)
    }
    return Buffer.concat(out)
  }

  private advance(): void {
    const unit = this.unit
    this.unit = Buffer.alloc(0)
    switch (this.phase) {
      case "version":
        this.phase = unit.toString("latin1") === "RFB 003.008\n" ? "security" : "passthrough"
        return
      case "security":
        this.phase = unit[0] === 1 ? "clientInit" : unit[0] === 2 ? "authentication" : "passthrough"
        return
      case "authentication":
        this.phase = "clientInit"
        return
      default:
        this.phase = "messages"
    }
  }

  private message(): [number, RFBClientMessageKind | "passthrough"] | undefined {
    const buffer = this.buffer
    if (buffer.length < 1) return undefined
    const need = (length: number, kind: RFBClientMessageKind) =>
      buffer.length < length ? undefined : ([length, kind] as [number, RFBClientMessageKind])
    switch (buffer[0]) {
      case 0:
        return need(20, "other")
      case 2:
        return buffer.length < 4 ? undefined : need(4 + 4 * buffer.readUInt16BE(2), "other")
      case 3:
        return need(10, "other")
      case 4:
        return need(8, "input")
      case 5:
        return need(6, "input")
      case 6:
        return buffer.length < 8
          ? undefined
          : need(8 + Math.abs(buffer.readInt32BE(4)), "clipboard")
      case 150:
        return need(10, "other")
      case 248:
        return buffer.length < 9 ? undefined : need(9 + buffer.readUInt8(8), "other")
      case 251:
        return buffer.length < 8 ? undefined : need(8 + 16 * buffer.readUInt8(6), "resize")
      default:
        this.phase = "passthrough"
        return [0, "passthrough"]
    }
  }
}
