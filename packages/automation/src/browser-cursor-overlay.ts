/**
 * The in-page half of the Browser Use cursor presentation. `pointerOverlay` is stringified and
 * evaluated inside the tab, so it must stay self-contained: no imports, no closure references,
 * and nothing the page's CSP could refuse. All styling goes through the CSSOM (never inline
 * `<style>` or `style=""` attributes) and the tree is built with DOM APIs rather than innerHTML so
 * Trusted Types enforcement is not tripped.
 */

export interface PointerCommand {
  readonly kind: "move" | "track" | "pulse" | "hide" | "inspect"
  readonly session?: string
  readonly color?: number
  readonly side?: number
  readonly x?: number
  readonly y?: number
}

export interface PointerReply {
  readonly duration: number
  readonly visible: boolean
  readonly cursors?: ReadonlyArray<{
    readonly session: string
    readonly color: number
    readonly x: number
    readonly y: number
    readonly pulses: number
    readonly shown: boolean
  }>
}

/* v8 ignore start -- this function only ever runs inside the page via Runtime.evaluate; the
 * headless Chromium test in browser-use-provider.test.ts exercises it end to end. */
const pointerOverlay = (command: PointerCommand): PointerReply => {
  const LAYER_ID = "codevisor-pointer-layer"
  const VERSION = 1
  const PALETTE: ReadonlyArray<readonly [number, number, number]> = [
    [0.35, 0.34, 0.84], // indigo
    [0.83, 0.32, 0.31], // coral
    [0.13, 0.55, 0.45], // teal
    [0.8, 0.47, 0.13], // amber
    [0.61, 0.31, 0.73], // purple
    [0.17, 0.47, 0.82], // blue
    [0.78, 0.31, 0.6], // magenta
    [0.42, 0.56, 0.14] // olive
  ]
  // The Computer Use pointer artwork (open-codex-computer-use, MIT). Tip is at (12, 3).
  const POINTER_PATH =
    "M19.8683 18.4886L13.8696 4.16156C13.7257 3.82006 13.4698 3.52606 13.1358 3.31858C12.8019 3.11111 12.4058 3 12 3C11.5942 3 11.1981 3.11111 10.8642 3.31858C10.5302 3.52606 10.2743 3.82006 10.1304 4.16156L4.13171 18.4886C3.97804 18.8506 3.95828 19.2476 4.07537 19.6206C4.19245 19.9935 4.44013 20.3224 4.78157 20.5585C5.1751 20.8443 5.66562 20.9999 6.17127 20.9995C6.6085 20.9989 7.03599 20.8832 7.401 20.6665L12 17.9127L16.599 20.6665C16.9918 20.9012 17.4574 21.0173 17.9283 20.9979C18.3993 20.9785 18.8512 20.8246 19.2184 20.5585C19.5599 20.3224 19.8075 19.9935 19.9246 19.6206C20.0417 19.2476 20.022 18.8506 19.8683 18.4886Z"
  // ~14×16 px, matching the native Computer Use pointer (15×17 pt) rather than a page cursor.
  const POINTER_SCALE = 0.9
  const HALO_RADIUS = 20
  const POINTER_ROTATION = -32
  const MOVE_MIN = 220
  const MOVE_MAX = 620
  const PULSE_MS = 180
  const RING_MS = 320
  const IDLE_RELEASE_MS = 60_000

  interface Travel {
    readonly fromX: number
    readonly fromY: number
    readonly toX: number
    readonly toY: number
    readonly c1x: number
    readonly c1y: number
    readonly c2x: number
    readonly c2y: number
    readonly start: number
    readonly duration: number
  }

  interface Cursor {
    readonly session: string
    readonly color: number
    readonly side: number
    readonly element: HTMLDivElement
    readonly halo: HTMLDivElement
    readonly ring: HTMLDivElement
    readonly body: SVGGElement
    readonly pointer: SVGPathElement
    readonly born: number
    x: number
    y: number
    tilt: number
    shown: boolean
    pulses: number
    lastActive: number
    lastFrame: number
    travel: Travel | undefined
    pulse: number | undefined
    removing: boolean
  }

  interface Layer {
    readonly version: number
    readonly root: ShadowRoot
    readonly cursors: Map<string, Cursor>
    frame: number
    tick: () => void
  }

  type Host = HTMLDivElement & { __codevisorPointer?: Layer }

  const idle: PointerReply = { duration: 0, visible: false }
  if (typeof document === "undefined" || document.documentElement === null) return idle

  const clamp = (value: number, low: number, high: number): number =>
    Math.min(high, Math.max(low, value))
  const now = (): number => performance.now()
  const rgba = (color: readonly [number, number, number], alpha: number): string =>
    `rgba(${Math.round(color[0] * 255)}, ${Math.round(color[1] * 255)}, ${Math.round(
      color[2] * 255
    )}, ${alpha})`
  const style = (element: ElementCSSInlineStyle, properties: Record<string, string>): void => {
    for (const [property, value] of Object.entries(properties)) {
      element.style.setProperty(property, value)
    }
  }
  const svgElement = <K extends keyof SVGElementTagNameMap>(
    tag: K,
    attributes: Record<string, string>,
    parent: Element
  ): SVGElementTagNameMap[K] => {
    const element = document.createElementNS("http://www.w3.org/2000/svg", tag)
    for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value)
    parent.append(element)
    return element
  }
  const hidden = (): boolean =>
    document.visibilityState === "hidden" ||
    (typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches)

  const existingHost = (): Host | undefined => {
    const host = document.getElementById(LAYER_ID) as Host | null
    if (host === null) return undefined
    if (host.__codevisorPointer?.version === VERSION) return host
    host.remove()
    return undefined
  }

  const bezier = (travel: Travel, t: number): { x: number; y: number } => {
    const u = 1 - t
    const a = u * u * u
    const b = 3 * u * u * t
    const c = 3 * u * t * t
    const d = t * t * t
    return {
      x: a * travel.fromX + b * travel.c1x + c * travel.c2x + d * travel.toX,
      y: a * travel.fromY + b * travel.c1y + c * travel.c2y + d * travel.toY
    }
  }

  const removeCursor = (layer: Layer, cursor: Cursor): void => {
    cursor.removing = true
    style(cursor.element, { opacity: "0" })
    layer.cursors.delete(cursor.session)
    setTimeout(() => {
      cursor.element.remove()
      if (layer.cursors.size === 0) layer.root.host.remove()
    }, 200)
  }

  const render = (layer: Layer, cursor: Cursor, time: number): boolean => {
    let active = false
    const travel = cursor.travel
    if (travel !== undefined) {
      const raw = clamp((time - travel.start) / Math.max(1, travel.duration), 0, 1)
      const eased = 1 - Math.pow(1 - raw, 3)
      const point = bezier(travel, eased)
      const frameSeconds = Math.max(1, time - cursor.lastFrame) / 1000
      const velocityX = (point.x - cursor.x) / frameSeconds
      cursor.x = point.x
      cursor.y = point.y
      // Lean into the direction of travel, like the macOS pointer does.
      const lean = clamp(velocityX * 0.00035, -0.18, 0.18)
      cursor.tilt += (lean - cursor.tilt) * 0.3
      if (raw >= 1) {
        cursor.x = travel.toX
        cursor.y = travel.toY
        cursor.travel = undefined
      }
      active = true
    } else {
      cursor.tilt *= 0.82
    }
    cursor.lastFrame = time

    let click = 0
    let ringProgress = 1
    if (cursor.pulse !== undefined) {
      const pulseProgress = clamp((time - cursor.pulse) / PULSE_MS, 0, 1)
      click = Math.sin(pulseProgress * Math.PI)
      ringProgress = clamp((time - cursor.pulse) / RING_MS, 0, 1)
      if (pulseProgress >= 1 && ringProgress >= 1) cursor.pulse = undefined
      active = true
    }

    const sway = Math.sin(((time - cursor.born) / 1000) * 1.6) * 0.06
    const degrees = POINTER_ROTATION + ((cursor.tilt + sway) * 180) / Math.PI
    style(cursor.element, {
      transform: `translate3d(${cursor.x.toFixed(2)}px, ${cursor.y.toFixed(2)}px, 0)`
    })
    cursor.body.setAttribute(
      "transform",
      `rotate(${degrees.toFixed(2)}) scale(${(1 - click * 0.04).toFixed(3)} ${(
        1 +
        click * 0.02
      ).toFixed(3)})`
    )
    style(cursor.pointer, {
      filter: `drop-shadow(0 0.35px ${(3.2 + click * 1.4).toFixed(2)}px rgba(0, 0, 0, ${(
        0.11 +
        click * 0.08
      ).toFixed(3)}))`
    })
    style(cursor.halo, {
      transform: `scale(${(1 + click * 0.08).toFixed(3)})`,
      opacity: (0.78 + click * 0.22).toFixed(3)
    })
    const ringRadius = 4 + ringProgress * 13
    style(cursor.ring, {
      width: `${(ringRadius * 2).toFixed(1)}px`,
      height: `${(ringRadius * 2).toFixed(1)}px`,
      left: `${(-ringRadius).toFixed(1)}px`,
      top: `${(-ringRadius).toFixed(1)}px`,
      opacity: ringProgress >= 1 ? "0" : ((1 - ringProgress) * 0.55).toFixed(3),
      "border-width": `${(2 - ringProgress).toFixed(2)}px`
    })

    if (!cursor.removing && time - cursor.lastActive > IDLE_RELEASE_MS) removeCursor(layer, cursor)
    return active || cursor.shown
  }

  const ensureLayer = (): Layer => {
    const host = existingHost()
    if (host?.__codevisorPointer !== undefined) return host.__codevisorPointer
    const created = document.createElement("div") as Host
    created.id = LAYER_ID
    created.setAttribute("aria-hidden", "true")
    created.setAttribute("data-codevisor", "pointer-overlay")
    style(created, {
      position: "fixed",
      inset: "0",
      "pointer-events": "none",
      "z-index": "2147483647",
      overflow: "visible",
      margin: "0",
      padding: "0",
      border: "0",
      transform: "none"
    })
    const root = created.attachShadow({ mode: "closed" })
    const layer: Layer = {
      version: VERSION,
      root,
      cursors: new Map(),
      frame: 0,
      tick: () => undefined
    }
    layer.tick = () => {
      const time = now()
      let active = false
      for (const cursor of [...layer.cursors.values()])
        active = render(layer, cursor, time) || active
      layer.frame = active ? requestAnimationFrame(layer.tick) : 0
    }
    created.__codevisorPointer = layer
    document.documentElement.append(created)
    return layer
  }

  const wake = (layer: Layer): void => {
    if (layer.frame === 0) layer.frame = requestAnimationFrame(layer.tick)
  }

  const cursorFor = (layer: Layer, session: string, color: number, side: number): Cursor => {
    const existing = layer.cursors.get(session)
    if (existing !== undefined) return existing
    const tint = PALETTE[((color % PALETTE.length) + PALETTE.length) % PALETTE.length]!
    const fog = tint.map((channel) => channel * 0.45 + 0.42 * 0.55) as unknown as readonly [
      number,
      number,
      number
    ]
    const element = document.createElement("div")
    style(element, {
      position: "absolute",
      left: "0",
      top: "0",
      width: "0",
      height: "0",
      opacity: "0",
      transition: "opacity 160ms ease-out",
      "will-change": "transform, opacity",
      "pointer-events": "none"
    })
    const halo = document.createElement("div")
    style(halo, {
      position: "absolute",
      left: `${2 - HALO_RADIUS}px`,
      top: `${5.5 - HALO_RADIUS}px`,
      width: `${HALO_RADIUS * 2}px`,
      height: `${HALO_RADIUS * 2}px`,
      "border-radius": "50%",
      "transform-origin": "50% 50%",
      // closest-side puts the transparent stop exactly on the rim; the extra stops give an
      // ease-out falloff so the glow dissolves into the page instead of ending at a clipped edge.
      background: `radial-gradient(circle closest-side, ${rgba(fog, 0.3)} 0%, ${rgba(fog, 0.24)} 30%, ${rgba(fog, 0.14)} 55%, ${rgba(fog, 0.06)} 75%, ${rgba(fog, 0.015)} 90%, ${rgba(fog, 0)} 100%)`
    })
    const ring = document.createElement("div")
    style(ring, {
      position: "absolute",
      "border-radius": "50%",
      "border-style": "solid",
      "border-color": rgba(tint, 1),
      "box-sizing": "border-box",
      opacity: "0"
    })
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("width", "48")
    svg.setAttribute("height", "48")
    svg.setAttribute("viewBox", "-24 -24 48 48")
    style(svg, { position: "absolute", left: "-24px", top: "-24px", overflow: "visible" })
    const body = svgElement("g", {}, svg)
    const pointer = svgElement(
      "path",
      {
        d: POINTER_PATH,
        transform: `scale(${POINTER_SCALE}) translate(-12 -3)`,
        fill: rgba(tint, 0.94),
        stroke: "rgba(230, 230, 230, 0.92)",
        "stroke-width": "1.25",
        "stroke-linejoin": "round",
        "stroke-linecap": "round",
        "vector-effect": "non-scaling-stroke"
      },
      body
    )
    element.append(halo, ring, svg)
    layer.root.append(element)
    const time = now()
    const cursor: Cursor = {
      session,
      color,
      side: side < 0 ? -1 : 1,
      element,
      halo,
      ring,
      body,
      pointer,
      born: time,
      x: innerWidth / 2,
      y: innerHeight / 2,
      tilt: 0,
      shown: false,
      pulses: 0,
      lastActive: time,
      lastFrame: time,
      travel: undefined,
      pulse: undefined,
      removing: false
    }
    layer.cursors.set(session, cursor)
    render(layer, cursor, time)
    return cursor
  }

  const show = (cursor: Cursor): void => {
    if (cursor.shown) return
    cursor.shown = true
    // Force the initial transform to land before the opacity transition starts.
    void cursor.element.offsetWidth
    style(cursor.element, { opacity: "1" })
  }

  const target = (): { x: number; y: number } => ({
    x: typeof command.x === "number" && Number.isFinite(command.x) ? command.x : 0,
    y: typeof command.y === "number" && Number.isFinite(command.y) ? command.y : 0
  })

  if (command.kind === "inspect") {
    const layer = existingHost()?.__codevisorPointer
    return {
      duration: 0,
      visible: !hidden(),
      cursors: [...(layer?.cursors.values() ?? [])].map((cursor) => ({
        session: cursor.session,
        color: cursor.color,
        x: cursor.x,
        y: cursor.y,
        pulses: cursor.pulses,
        shown: cursor.shown
      }))
    }
  }

  const session = typeof command.session === "string" ? command.session : ""
  if (session.length === 0) return idle

  if (command.kind === "hide") {
    const layer = existingHost()?.__codevisorPointer
    const cursor = layer?.cursors.get(session)
    if (layer !== undefined && cursor !== undefined) removeCursor(layer, cursor)
    return idle
  }

  const layer = ensureLayer()
  const cursor = cursorFor(
    layer,
    session,
    typeof command.color === "number" ? command.color : 0,
    typeof command.side === "number" ? command.side : 1
  )
  const point = target()
  const time = now()
  cursor.lastActive = time
  const visible = !hidden()

  if (command.kind === "pulse") {
    cursor.travel = undefined
    cursor.x = point.x
    cursor.y = point.y
    cursor.pulse = time
    cursor.pulses += 1
    show(cursor)
    wake(layer)
    return { duration: visible ? PULSE_MS : 0, visible }
  }

  const fromX = cursor.x
  const fromY = cursor.y
  const distance = Math.hypot(point.x - fromX, point.y - fromY)
  const instant = command.kind === "track" || !visible || distance < 0.5
  if (instant) {
    cursor.travel = undefined
    cursor.x = point.x
    cursor.y = point.y
    render(layer, cursor, time)
    show(cursor)
    wake(layer)
    return { duration: 0, visible }
  }

  const duration = Math.min(MOVE_MAX, Math.max(MOVE_MIN, 180 + distance / 1.35))
  const bulge = Math.min(86, Math.max(18, distance * 0.16)) * cursor.side
  const normalX = (-(point.y - fromY) / distance) * bulge
  const normalY = ((point.x - fromX) / distance) * bulge
  cursor.travel = {
    fromX,
    fromY,
    toX: point.x,
    toY: point.y,
    c1x: fromX + (point.x - fromX) * 0.3 + normalX,
    c1y: fromY + (point.y - fromY) * 0.3 + normalY,
    c2x: fromX + (point.x - fromX) * 0.7 + normalX,
    c2y: fromY + (point.y - fromY) * 0.7 + normalY,
    start: time,
    duration
  }
  cursor.lastFrame = time
  show(cursor)
  wake(layer)
  return { duration: Math.round(duration), visible }
}

/* v8 ignore stop */

/** Source of the page-side overlay, evaluated as `(source)(command)`. */
export const pointerOverlaySource: string = pointerOverlay.toString()

export const pointerOverlayExpression = (command: PointerCommand): string =>
  `(${pointerOverlaySource})(${JSON.stringify(command)})`
