import type { TerminalServerFrame } from "@codevisor/api"

export const REPLAY_BUFFER_MAX_BYTES = 2 * 1024 * 1024

const CONTROL_FRAME_BYTES = 16

const frameBytes = (frame: TerminalServerFrame): number =>
  frame.type === "output" ? Buffer.byteLength(frame.data, "utf8") : CONTROL_FRAME_BYTES

export class ReplayBuffer {
  private frames: Array<TerminalServerFrame> = []
  private sizes: Array<number> = []
  private head = 0
  private retainedBytes = 0

  constructor(private readonly maxBytes: number = REPLAY_BUFFER_MAX_BYTES) {}

  get bytes(): number {
    return this.retainedBytes
  }

  get length(): number {
    return this.frames.length - this.head
  }

  get firstSeq(): number | undefined {
    return this.frames[this.head]?.seq
  }

  push(frame: TerminalServerFrame): void {
    const size = frameBytes(frame)
    this.frames.push(frame)
    this.sizes.push(size)
    this.retainedBytes += size
    while (this.retainedBytes > this.maxBytes && this.length > 1) {
      this.retainedBytes -= this.sizes[this.head]!
      this.head += 1
    }
    if (this.head > 1024 && this.head * 2 > this.frames.length) {
      this.frames = this.frames.slice(this.head)
      this.sizes = this.sizes.slice(this.head)
      this.head = 0
    }
  }

  since(lastOutputSeq: number): Array<TerminalServerFrame> {
    const firstSeq = this.firstSeq
    if (firstSeq === undefined) return []
    const offset = Math.max(0, lastOutputSeq + 1 - firstSeq)
    return this.frames.slice(this.head + offset)
  }
}
