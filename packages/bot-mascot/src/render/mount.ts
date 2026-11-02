import { palette, type Palette } from "../color/palette.js"
import type { BotMascotPose } from "../pose.js"
import { renderContext, type RenderContext } from "./context.js"
import { frameParts, renderFrame, type FrameOptions, type FrameParts } from "./frame.js"

export type MountedDraw = (color: string, pose: BotMascotPose, opts?: FrameOptions) => void

export interface MountNode {
  innerHTML: string
  getAttribute(name: string): string | null
  setAttribute(name: string, value: string): void
}

export interface MountHost {
  innerHTML: string
  querySelectorAll(selector: string): Iterable<MountNode>
}

interface Mounted {
  readonly key: string
  readonly P: Palette
  readonly nodes: ReadonlyMap<string, MountNode>
  readonly last: Map<string, string>
}

export function mountBotMascot(
  el: MountHost,
  uid = "live",
  makeContext: () => RenderContext = renderContext
): MountedDraw {
  let mounted: Mounted | null = null
  return (color, pose, opts = {}) => {
    const ctx = makeContext()
    if (mounted?.key !== color) {
      el.innerHTML = renderFrame(ctx, color, pose, { ...opts, uid })
      mounted = { key: color, P: palette(color), nodes: roleNodes(el), last: new Map() }
      return
    }
    update(mounted, frameParts(ctx, mounted.P, pose, uid), opts.viewBox)
  }
}

function roleNodes(el: MountHost): ReadonlyMap<string, MountNode> {
  const nodes = new Map<string, MountNode>()
  for (const n of el.querySelectorAll("[data-r]")) nodes.set(n.getAttribute("data-r") ?? "", n)
  return nodes
}

function update(m: Mounted, F: FrameParts, viewBox: string | undefined): void {
  const attr = (role: string, name: string, v: string): void => {
    const k = role + name
    if (m.last.get(k) === v) return
    m.last.set(k, v)
    m.nodes.get(role)?.setAttribute(name, v)
  }
  const html = (role: string, v: string): void => {
    if (m.last.get(role) === v) return
    m.last.set(role, v)
    const node = m.nodes.get(role)
    if (node) node.innerHTML = v
  }
  if (viewBox) attr("root", "viewBox", viewBox)
  attr("tf", "transform", F.tf)
  attr("shadow", "rx", F.shadow[0])
  attr("shadow", "ry", F.shadow[1])
  attr("shadow", "fill", F.shadow[2])
  for (const role of ["body", "clip", "mask"]) attr(role, "d", F.d)
  for (const role of ["eye", "mkt", "ewt"]) attr(role, "transform", F.eyeTf)
  html("eyewear", F.eyewear)
  html("makeup", F.makeup)
  attr("hat", "transform", F.hatTf)
  html("wear", F.wear)
  attr("wear", "opacity", F.wearOp)
  html("creases", F.creases)
  html("drape", F.drape)
  html("face", F.face)
  html("hatc", F.hat)
  html("fx", F.fx)
}
