import { CheckIcon, CopyIcon } from "lucide-react"
import { useEffect, useRef, useState } from "react"

async function copyText(text: string) {
  if (navigator.clipboard?.writeText != null) {
    await navigator.clipboard.writeText(text)
    return
  }

  const element = document.createElement("textarea")
  element.value = text
  element.setAttribute("readonly", "")
  element.style.position = "fixed"
  element.style.opacity = "0"
  document.body.appendChild(element)
  element.select()
  document.execCommand("copy")
  document.body.removeChild(element)
}

// Hover-revealed transcript copy control, matching MessageCopyButton.swift.
export function MessageCopyButton({
  text,
  label = "Copy message",
  isRevealed = true
}: {
  text: string
  label?: string
  isRevealed?: boolean
}) {
  const [didCopy, setDidCopy] = useState(false)
  const timerRef = useRef<number | undefined>(undefined)

  useEffect(() => {
    if (isRevealed) return
    setDidCopy(false)
  }, [isRevealed])

  useEffect(() => {
    return () => {
      if (timerRef.current != null) window.clearTimeout(timerRef.current)
    }
  }, [])

  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      className="text-muted-foreground flex size-[22px] cursor-default items-center justify-center rounded-[6px] outline-none hover:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] active:opacity-80"
      onClick={async () => {
        await copyText(text)
        setDidCopy(true)
        if (timerRef.current != null) window.clearTimeout(timerRef.current)
        timerRef.current = window.setTimeout(() => setDidCopy(false), 1500)
      }}
    >
      {didCopy ? <CheckIcon className="size-3.5" /> : <CopyIcon className="size-3.5" />}
    </button>
  )
}
