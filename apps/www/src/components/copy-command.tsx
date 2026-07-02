import { useState } from "react"

export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false)

  const copy = () => {
    navigator.clipboard.writeText(command).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    })
  }

  return (
    <button
      type="button"
      onClick={copy}
      className="group flex w-full items-center gap-3 rounded-xl border border-hairline bg-white/[0.04] px-4 py-3 text-left font-mono text-[13px] text-muted transition-colors hover:text-text"
      aria-label={`Copy command: ${command}`}
    >
      <span className="flex-1 overflow-x-auto whitespace-nowrap">{command}</span>
      <span className="shrink-0 text-[11px] tracking-widest uppercase opacity-60">
        {copied ? "copied" : "copy"}
      </span>
    </button>
  )
}
