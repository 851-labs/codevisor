export interface VNCRelay {
  readonly screen?: boolean
  readonly configured: string
  readonly dialled: string
  readonly close: (reason: string) => void
}

const recheckEveryMs = 5000

export class VNCRelays {
  private readonly open = new Set<VNCRelay>()
  private timer: NodeJS.Timeout | undefined

  constructor(private readonly whyNotShared: (relay: VNCRelay) => string | undefined) {}

  add(relay: VNCRelay): () => void {
    this.open.add(relay)
    this.timer ??= setInterval(() => this.recheck(), recheckEveryMs).unref()
    return () => this.leave(relay)
  }

  recheck(): void {
    for (const relay of this.open) {
      const reason = this.whyNotShared(relay)
      if (reason === undefined) continue

      this.leave(relay)
      relay.close(reason)
    }
  }

  private leave(relay: VNCRelay): void {
    this.open.delete(relay)
    if (this.open.size > 0) return

    clearInterval(this.timer)
    this.timer = undefined
  }
}
