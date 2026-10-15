import { useState } from "react"

export const registryBaseUrl = (): string =>
  (import.meta.env.VITE_CODEVISOR_DEV_CLOUD_URL ?? "https://cloud.codevisor.dev").replace(
    /\/+$/,
    ""
  )

export const installCliCommand = (repo: string): string => `codevisor plugin install ${repo}`

const deeplinkScheme = (): string =>
  import.meta.env.VITE_CODEVISOR_DEV_URL_SCHEME ??
  (import.meta.env.DEV ? "codevisor-dev" : "codevisor")

export const installDeeplink = (repo: string): string =>
  `${deeplinkScheme()}://install-plugin?repo=${encodeURIComponent(repo)}`

export function PluginAvatar({ avatarUrl, sizeClass }: { avatarUrl?: string; sizeClass: string }) {
  if (avatarUrl === undefined) {
    return (
      <div
        aria-hidden
        className={`${sizeClass} flex shrink-0 items-center justify-center rounded-[24%] border border-hairline bg-white/[0.06] text-muted`}
      >
        <PuzzleGlyph />
      </div>
    )
  }
  return (
    <img
      src={avatarUrl}
      alt=""
      loading="lazy"
      className={`${sizeClass} shrink-0 rounded-[24%] border border-hairline bg-white/[0.06] object-cover`}
    />
  )
}

function PuzzleGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="size-1/2" fill="none" aria-hidden>
      <path
        d="M10 3.5a1.75 1.75 0 1 1 3.5 0V5H17a1 1 0 0 1 1 1v3.5h1.25a1.75 1.75 0 1 1 0 3.5H18V17a1 1 0 0 1-1 1h-3.5v-1.25a1.75 1.75 0 1 0-3.5 0V18H7a1 1 0 0 1-1-1v-3.5H4.75a1.75 1.75 0 1 1 0-3.5H6V6a1 1 0 0 1 1-1h3V3.5Z"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinejoin="round"
      />
    </svg>
  )
}

export function InstallButton({ repo, prominent = false }: { repo: string; prominent?: boolean }) {
  return (
    <a
      href={installDeeplink(repo)}
      className={
        prominent
          ? "inline-flex shrink-0 items-center gap-1.5 rounded-full bg-white px-4 py-1.5 text-sm font-medium text-black transition-opacity hover:opacity-85"
          : "inline-flex shrink-0 items-center rounded-full border border-hairline px-3.5 py-1 text-sm font-medium text-text transition-colors hover:bg-white/[0.08]"
      }
      title="Opens Codevisor and installs after your confirmation"
    >
      Install
    </a>
  )
}

export function CopyInstallCommand({ repo }: { repo: string }) {
  const command = installCliCommand(repo)
  const [copied, setCopied] = useState(false)
  const copy = () => {
    void navigator.clipboard.writeText(command).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    })
  }
  return (
    <button
      type="button"
      onClick={copy}
      className="flex w-full items-center gap-3 rounded-lg border border-hairline px-3 py-2.5 text-left font-mono text-[12px] text-muted transition-colors hover:text-text"
      aria-label={`Copy command: ${command}`}
    >
      <span className="flex-1 overflow-x-auto whitespace-nowrap">{command}</span>
      <span className="shrink-0 text-[10px] tracking-widest uppercase opacity-60">
        {copied ? "copied" : "copy"}
      </span>
    </button>
  )
}
