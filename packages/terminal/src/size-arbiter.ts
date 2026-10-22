export interface TerminalSize {
  readonly cols: number
  readonly rows: number
}

export class SizeArbiter {
  private readonly visible = new Map<string, TerminalSize>()
  private owner: string | undefined

  constructor(private current: TerminalSize) {}

  get size(): TerminalSize {
    return this.current
  }

  resize(clientId: string, size: TerminalSize): TerminalSize | undefined {
    this.visible.set(clientId, size)
    this.owner ??= clientId
    if (this.owner === clientId) return this.apply(size)
    return undefined
  }

  claim(clientId: string): TerminalSize | undefined {
    const size = this.visible.get(clientId)
    if (size === undefined) return undefined
    this.visible.delete(clientId)
    this.visible.set(clientId, size)
    this.owner = clientId
    return this.apply(size)
  }

  hide(clientId: string): TerminalSize | undefined {
    if (!this.visible.delete(clientId) || this.owner !== clientId) return undefined
    this.owner = [...this.visible.keys()].at(-1)
    if (this.owner === undefined) return undefined
    return this.apply(this.visible.get(this.owner)!)
  }

  release(clientId: string): TerminalSize | undefined {
    return this.hide(clientId)
  }

  private apply(size: TerminalSize): TerminalSize | undefined {
    if (size.cols === this.current.cols && size.rows === this.current.rows) return undefined
    this.current = size
    return size
  }
}
