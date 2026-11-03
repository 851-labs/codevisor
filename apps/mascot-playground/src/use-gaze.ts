import { gazeFollower, type BotMascotGaze } from "@codevisor/bot-mascot"
import { useCallback, useEffect, useRef, useState } from "react"

export type Point = readonly [number, number]

export interface LiveGaze {
  readonly pointer: Point | null
  readonly gaze: BotMascotGaze | null
}

export const noGaze: LiveGaze = { pointer: null, gaze: null }

export function useGaze(active: boolean): {
  readonly live: LiveGaze
  readonly point: (pointer: Point | null) => void
} {
  const pointer = useRef<Point | null>(null)
  const [live, setLive] = useState(noGaze)
  const point = useCallback((p: Point | null) => {
    pointer.current = p
  }, [])

  useEffect(() => {
    if (!active) return undefined

    const follower = gazeFollower()
    let handle = 0
    let last = performance.now()
    const tick = (now: number) => {
      const gaze = follower.step(pointer.current, (now - last) / 1000)
      last = now
      setLive((shown) => changed(shown, pointer.current, gaze))
      handle = requestAnimationFrame(tick)
    }
    handle = requestAnimationFrame(tick)
    return () => {
      cancelAnimationFrame(handle)
      setLive(noGaze)
    }
  }, [active])

  return { live, point }
}

function changed(shown: LiveGaze, pointer: Point | null, gaze: BotMascotGaze | null): LiveGaze {
  if (!pointer && !gaze && !shown.pointer && !shown.gaze) return shown
  return { pointer, gaze }
}
