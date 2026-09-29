import type { TerminalServerFrame } from "@codevisor/api"

/// Default byte budget for a terminal's replay buffer. Long-lived shells and
/// dev servers stream indefinitely; the buffer only has to bridge short
/// disconnects, so older output is trimmed once the budget is exceeded.
export const REPLAY_BUFFER_MAX_BYTES = 2 * 1024 * 1024

/// Fixed accounting cost for non-output frames so they still count toward the
/// budget without measuring their (tiny) JSON encoding.
const CONTROL_FRAME_BYTES = 16

const frameBytes = (frame: TerminalServerFrame): number =>
  frame.type === "output" ? Buffer.byteLength(frame.data, "utf8") : CONTROL_FRAME_BYTES

/// Sequenced frames retained for reconnecting clients, bounded by bytes.
/// The newest frame is always kept, even when it alone exceeds the budget,
/// so a client that is merely one frame behind never misses output.
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

  /// Sequence number of the oldest retained frame, or undefined when empty.
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
    // Compact lazily so trimming stays amortized O(1) per frame.
    if (this.head > 1024 && this.head * 2 > this.frames.length) {
      this.frames = this.frames.slice(this.head)
      this.sizes = this.sizes.slice(this.head)
      this.head = 0
    }
  }

  /// Retained frames with `seq > lastOutputSeq`, oldest first. Sequence
  /// numbers are contiguous, so the start index is computed directly.
  since(lastOutputSeq: number): Array<TerminalServerFrame> {
    const firstSeq = this.firstSeq
    if (firstSeq === undefined) return []
    const offset = Math.max(0, lastOutputSeq + 1 - firstSeq)
    return this.frames.slice(this.head + offset)
  }
}
