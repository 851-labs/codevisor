import {
  DISCORD_INVITE_URL,
  DISCORD_LABEL,
  DiscordMark,
  DOWNLOAD_SECTION_URL,
  formatStars,
  GITHUB_REPO_URL,
  GitHubMark,
  githubLabel,
  StarGlyph,
  useGitHubStars
} from "./header-kit"

export function SiteNav() {
  const githubStars = useGitHubStars()
  return (
    <header className="fixed inset-x-0 top-0 z-40 border-b border-hairline bg-black/80 backdrop-blur-xl">
      <nav className="mx-auto flex h-11 max-w-5xl items-center justify-between px-6 text-xs">
        <a href="/" className="flex items-center gap-2 font-semibold tracking-tight text-text">
          <img src="/codevisor-icon.png" alt="" className="size-6 rounded" />
          Codevisor
        </a>
        <div className="flex items-center gap-6 text-muted">
          <a
            href={DISCORD_INVITE_URL}
            target="_blank"
            rel="noreferrer"
            className="flex items-center transition-colors hover:text-text"
            aria-label={DISCORD_LABEL}
          >
            <DiscordMark />
          </a>
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="flex items-center gap-1.5 transition-colors hover:text-text"
            aria-label={githubLabel(githubStars)}
          >
            <GitHubMark />
            {githubStars === null ? (
              <span>GitHub</span>
            ) : (
              <span className="flex items-center gap-1 tabular-nums">
                <StarGlyph />
                {formatStars(githubStars)}
              </span>
            )}
          </a>
          <a
            href={DOWNLOAD_SECTION_URL}
            className="rounded-full bg-text px-3 py-1 font-medium text-black transition-opacity hover:opacity-90"
          >
            Download
          </a>
        </div>
      </nav>
    </header>
  )
}
