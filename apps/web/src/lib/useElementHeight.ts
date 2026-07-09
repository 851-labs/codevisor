import { type RefCallback, useCallback, useRef, useState } from "react"

// Observes an element's rendered height (the web analog of the SwiftUI
// onGeometryChange pattern). Returns a ref callback and the latest height.
export function useElementHeight(): [RefCallback<HTMLElement>, number] {
  const [height, setHeight] = useState(0)
  const observerRef = useRef<ResizeObserver | undefined>(undefined)
  const refCallback = useCallback<RefCallback<HTMLElement>>((element) => {
    observerRef.current?.disconnect()
    if (element == null) return
    const observer = new ResizeObserver((entries) => {
      const entry = entries[0]
      if (entry != null) setHeight(entry.contentRect.height)
    })
    observer.observe(element)
    observerRef.current = observer
    setHeight(element.getBoundingClientRect().height)
  }, [])
  return [refCallback, height]
}
