import { describe, expect, it } from "vitest"

import { idleAt, mountBotMascot } from "../index.js"

class FakeNode {
  readonly writes: Array<string> = []
  private html = ""

  constructor(readonly role: string) {}

  get innerHTML(): string {
    return this.html
  }

  set innerHTML(v: string) {
    this.html = v
    this.writes.push("html")
  }

  getAttribute(name: string): string | null {
    return name === "data-r" ? this.role : null
  }

  setAttribute(name: string, _value: string): void {
    this.writes.push(name)
  }
}

class FakeHost {
  nodes: Array<FakeNode> = []
  renders = 0

  set innerHTML(svg: string) {
    this.renders++
    this.nodes = [...svg.matchAll(/data-r="([^"]+)"/g)].map((m) => new FakeNode(m[1]!))
  }

  querySelectorAll(): ReadonlyArray<FakeNode> {
    return this.nodes
  }
}

const node = (host: FakeHost, role: string): FakeNode => host.nodes.find((n) => n.role === role)!

describe("mountBotMascot", () => {
  it("builds the SVG once per color and then writes only what changed", () => {
    const host = new FakeHost()
    const draw = mountBotMascot(host)
    draw("sunny", idleAt(0))
    expect(host.renders).toBe(1)
    draw("sunny", idleAt(0.4))
    draw("sunny", idleAt(0.4))
    expect(host.renders).toBe(1)
    expect(node(host, "tf").writes).toEqual(["transform"])
    expect(node(host, "hatc").writes).toEqual(["html"])
    draw("mint", idleAt(0.4))
    expect(host.renders).toBe(2)
  })

  it("moves the camera when given a new viewBox", () => {
    const host = new FakeHost()
    const draw = mountBotMascot(host)
    draw("sky", idleAt(0))
    draw("sky", idleAt(0), { viewBox: "0 0 400 400" })
    expect(node(host, "root").writes).toContain("viewBox")
  })
})
