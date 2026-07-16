import { useState } from "react"

import { captureAnalytics, type InstallPlacement } from "../lib/analytics"

const TABS = [
  {
    id: "curl",
    label: "curl",
    command: "curl -fsSL https://www.codevisor.dev/install.sh | sh"
  },
  {
    id: "brew",
    label: "brew",
    command: "brew install --cask 851-labs/tap/codevisor"
  }
] as const

type TabId = (typeof TABS)[number]["id"]

export function InstallCommand({ placement }: { placement: InstallPlacement }) {
  const [active, setActive] = useState<TabId>("curl")
  const [copied, setCopied] = useState(false)

  const tab = TABS.find((t) => t.id === active) ?? TABS[0]

  const copy = () => {
    navigator.clipboard.writeText(tab.command).then(() => {
      captureAnalytics({
        name: "www install command copied",
        properties: { method: tab.id, placement }
      })
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    })
  }

  return (
    <div className="w-full overflow-hidden rounded-xl border border-hairline bg-white/[0.04] text-left">
      <div
        role="tablist"
        aria-label="Install method"
        className="flex items-center gap-1 border-b border-hairline px-2"
      >
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={t.id === active}
            onClick={() => {
              setActive(t.id)
              setCopied(false)
              if (t.id !== active) {
                captureAnalytics({
                  name: "www install method selected",
                  properties: { method: t.id, placement }
                })
              }
            }}
            className={`relative px-3 py-2.5 font-mono text-[13px] transition-colors ${
              t.id === active ? "text-text" : "text-muted hover:text-text"
            }`}
          >
            {t.label}
            {t.id === active && (
              <span aria-hidden className="absolute inset-x-3 -bottom-px h-px bg-text" />
            )}
          </button>
        ))}
      </div>
      <button
        type="button"
        onClick={copy}
        className="group flex w-full items-center gap-3 px-4 py-3.5 text-left font-mono text-[13px] text-muted transition-colors hover:text-text"
        aria-label={`Copy command: ${tab.command}`}
      >
        <span className="flex-1 overflow-x-auto whitespace-nowrap">{tab.command}</span>
        <span className="shrink-0 text-[11px] tracking-widest uppercase opacity-60">
          {copied ? "copied" : "copy"}
        </span>
      </button>
    </div>
  )
}
