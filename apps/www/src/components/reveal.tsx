import { useEffect, useRef, type CSSProperties, type ReactNode } from "react"

// Adds .is-visible when the element scrolls into view so CSS can play the
// rise animation. Elements render visible on the server; the class flip only
// happens client-side, so no-JS visitors still see everything.
export function Reveal({
  children,
  className = "",
  delay = 0
}: {
  children: ReactNode
  className?: string
  delay?: number
}) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const node = ref.current
    if (!node) return
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible")
            observer.unobserve(entry.target)
          }
        }
      },
      { threshold: 0.15 }
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [])

  const style: CSSProperties = delay ? { animationDelay: `${delay}ms` } : {}
  return (
    <div ref={ref} className={`reveal ${className}`} style={style}>
      {children}
    </div>
  )
}
