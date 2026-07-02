import { useState } from "react"

export function CopyCommand({ command, prompt = "$" }: { command: string; prompt?: string }) {
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
      className="group flex w-full items-center gap-3 rounded-xl border border-ink-border bg-black/60 px-4 py-3 text-left font-mono text-[13px] text-wool transition-colors hover:border-mint/40 hover:text-cloud"
      aria-label={`Copy command: ${command}`}
    >
      <span className="select-none text-mint">{prompt}</span>
      <span className="flex-1 overflow-x-auto whitespace-nowrap">{command}</span>
      <span className="shrink-0 text-[11px] uppercase tracking-widest text-wool/50 transition-colors group-hover:text-mint">
        {copied ? "copied" : "copy"}
      </span>
    </button>
  )
}
