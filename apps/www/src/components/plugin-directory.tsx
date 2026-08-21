import { useState } from "react"

/// Shared pieces of the plugin directory (codevisor.dev/plugins and the
/// per-plugin detail pages): artwork, the install affordances, and the page
/// chrome both routes render.

/// Registry base URL, resolved lazily so the dev runner's local cloud
/// instance wins over production. import.meta.env, not process.env: the SSR
/// handler runs on workerd, which has no process environment.
export const registryBaseUrl = (): string =>
  (
    (import.meta.env["VITE_CODEVISOR_DEV_CLOUD_URL"] as string | undefined) ??
    "https://cloud.codevisor.dev"
  ).replace(/\/+$/, "")

export const installCliCommand = (repo: string): string => `codevisor plugin install ${repo}`

/// The app deeplink the Install buttons open. The app never auto-installs
/// from it: it routes into the same discover→consent flow as an in-app
/// install, showing the verbatim commands first. A dev site targets its own
/// dev app: `bun run dev` registers a per-worktree scheme
/// (codevisor-dev-<hash>, via VITE_CODEVISOR_DEV_URL_SCHEME) so the Install
/// button opens the development instance this page belongs to — never a
/// production install or another worktree's dev app.
const deeplinkScheme = (): string =>
  (import.meta.env["VITE_CODEVISOR_DEV_URL_SCHEME"] as string | undefined) ??
  (import.meta.env.DEV ? "codevisor-dev" : "codevisor")

export const installDeeplink = (repo: string): string =>
  `${deeplinkScheme()}://install-plugin?repo=${encodeURIComponent(repo)}`

/// The repo owner's GitHub avatar in an app-icon-style rounded rect, with a
/// neutral placeholder when the index predates avatar support.
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

/// The primary install affordance: opens the app via the
/// codevisor://install-plugin deeplink.
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

/// The CLI fallback: click to copy `codevisor plugin install owner/repo`.
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
