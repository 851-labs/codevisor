import { useEffect, useRef, useState } from "react"

export function useThrottled<T>(value: T, intervalMs: number): T {
  const [shown, setShown] = useState(value)
  const last = useRef(0)

  useEffect(() => {
    const wait = Math.max(0, last.current + intervalMs - performance.now())
    const handle = setTimeout(() => {
      last.current = performance.now()
      setShown(value)
    }, wait)
    return () => clearTimeout(handle)
  }, [value, intervalMs])

  return shown
}
