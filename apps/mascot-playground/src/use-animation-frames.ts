import { useEffect, useLayoutEffect, useRef } from "react"

export function useAnimationFrames(running: boolean, onFrame: (elapsedSeconds: number) => void) {
  const latest = useRef(onFrame)
  useLayoutEffect(() => {
    latest.current = onFrame
  })

  useEffect(() => {
    if (!running) return undefined

    let handle = 0
    let last = performance.now()
    const tick = (now: number) => {
      latest.current((now - last) / 1000)
      last = now
      handle = requestAnimationFrame(tick)
    }
    handle = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(handle)
  }, [running])
}
