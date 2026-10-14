export class VNCControlArbiter {
  private readonly viewers = new Map<
    number,
    { send: (text: string) => void; arbitrated: boolean }
  >()
  private controller: number | undefined
  private nextId = 1
  private latest: number | undefined

  join(send: (text: string) => void): number {
    const id = this.nextId++
    this.viewers.set(id, { send, arbitrated: false })
    this.latest = id
    return id
  }

  leave(id: number): void {
    this.viewers.delete(id)
    if (this.controller === id) this.controller = undefined
    if (this.latest === id) this.latest = [...this.viewers.keys()].at(-1)
  }

  receive(id: number, text: string): void {
    const viewer = this.viewers.get(id)
    if (viewer === undefined) return
    let message: unknown
    try {
      message = JSON.parse(text)
    } catch {
      return
    }
    if (typeof message !== "object" || message === null) return
    const { type, name } = message as { type?: unknown; name?: unknown }
    viewer.arbitrated = true
    if (type === "request") {
      const previous = this.controller
      this.controller = id
      if (previous !== undefined && previous !== id) {
        const by =
          typeof name === "string" && name.trim() !== ""
            ? name.trim().slice(0, 100)
            : "Another viewer"
        this.viewers.get(previous)?.send(JSON.stringify({ type: "revoked", by }))
      }
      viewer.send(JSON.stringify({ type: "granted" }))
    } else if (type === "release" && this.controller === id) {
      this.controller = undefined
    }
  }

  mayControl(id: number): boolean {
    const viewer = this.viewers.get(id)
    return viewer !== undefined && (!viewer.arbitrated || this.controller === id)
  }

  mayResize(id: number): boolean {
    const viewer = this.viewers.get(id)
    if (viewer === undefined) return false
    if (!viewer.arbitrated) return true
    return this.controller === undefined ? this.latest === id : this.controller === id
  }
}

const arbiters = new Map<number, VNCControlArbiter>()

export const vncControlArbiter = (port: number): VNCControlArbiter => {
  let arbiter = arbiters.get(port)
  if (arbiter === undefined) {
    arbiter = new VNCControlArbiter()
    arbiters.set(port, arbiter)
  }
  return arbiter
}
