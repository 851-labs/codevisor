/// What a viewer's RFB message does, for the control lease (851-2338).
export type RFBClientMessageKind = "input" | "clipboard" | "resize" | "other"

/// Follows one viewer's client→server RFB stream (RFB 3.8, None or VNC
/// authentication) message by message and drops the ones `allow` refuses,
/// keeping every other byte in order. Handshake bytes always pass. Anything it
/// can't follow (another protocol version or security type, an unknown message
/// type) switches it to pass-through for the rest of the connection: never a
/// corrupted stream, at worst an unfiltered one.
export class RFBClientStreamFilter {
  private buffer: Buffer = Buffer.alloc(0)
  private phase:
    | "version"
    | "security"
    | "authentication"
    | "clientInit"
    | "messages"
    | "passthrough" = "version"
  /// The handshake unit being read (never dropped, so its bytes are forwarded as they come).
  private unit: Buffer = Buffer.alloc(0)

  /// The bytes of `chunk` (with any held partial message) to forward now.
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

  /// A complete handshake unit: on to the next phase, or pass-through for anything unexpected.
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

  /// The next complete message's length and kind; undefined until it's all here.
  private message(): [number, RFBClientMessageKind | "passthrough"] | undefined {
    const buffer = this.buffer
    if (buffer.length < 1) return undefined
    const need = (length: number, kind: RFBClientMessageKind) =>
      buffer.length < length ? undefined : ([length, kind] as [number, RFBClientMessageKind])
    switch (buffer[0]) {
      case 0: // SetPixelFormat
        return need(20, "other")
      case 2: // SetEncodings
        return buffer.length < 4 ? undefined : need(4 + 4 * buffer.readUInt16BE(2), "other")
      case 3: // FramebufferUpdateRequest
        return need(10, "other")
      case 4: // KeyEvent
        return need(8, "input")
      case 5: // PointerEvent
        return need(6, "input")
      case 6: // ClientCutText; a negative length is Extended Clipboard
        return buffer.length < 8
          ? undefined
          : need(8 + Math.abs(buffer.readInt32BE(4)), "clipboard")
      case 150: // EnableContinuousUpdates
        return need(10, "other")
      case 248: // Fence
        return buffer.length < 9 ? undefined : need(9 + buffer.readUInt8(8), "other")
      case 251: // SetDesktopSize
        return buffer.length < 8 ? undefined : need(8 + 16 * buffer.readUInt8(6), "resize")
      default:
        this.phase = "passthrough"
        return [0, "passthrough"]
    }
  }
}
