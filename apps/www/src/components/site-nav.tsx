import {
  CodevisorMark,
  DISCORD_INVITE_URL,
  DISCORD_LABEL,
  DiscordMark,
  DOWNLOAD_SECTION_URL,
  formatStars,
  GITHUB_REPO_URL,
  GitHubMark,
  githubLabel,
  useGitHubStars
} from "./header-kit"

export function SiteNav() {
  const stars = useGitHubStars()
  return (
    <header className="sticky top-0 z-40 flex h-14 items-center justify-between border-b border-hairline bg-page/80 px-5 text-[14px] backdrop-blur-xl backdrop-saturate-150 sm:px-8">
      <a
        href="/"
        draggable={false}
        className="flex items-center gap-[5px] text-[16px] font-semibold tracking-[-0.015em]"
      >
        <CodevisorMark />
        Codevisor
      </a>
      <nav className="flex items-center gap-4 sm:gap-5">
        <a
          href={GITHUB_REPO_URL}
          target="_blank"
          rel="noreferrer"
          aria-label={githubLabel(stars)}
          className="flex items-center gap-1 text-muted transition-colors hover:text-text"
        >
          <GitHubMark className="size-3.5" />
          <span className="tabular-nums">{stars === null ? "GitHub" : formatStars(stars)}</span>
        </a>
        <a
          href={DISCORD_INVITE_URL}
          target="_blank"
          rel="noreferrer"
          aria-label={DISCORD_LABEL}
          className="flex items-center gap-1.5 text-muted transition-colors hover:text-text"
        >
          <DiscordMark className="size-4" />
        </a>
        <a
          href={DOWNLOAD_SECTION_URL}
          className="rounded-full bg-[light-dark(#161618,#f4f4f6)] px-4 py-1.5 font-semibold text-[light-dark(#ffffff,#111111)] transition-opacity hover:opacity-85"
        >
          Download
        </a>
      </nav>
    </header>
  )
}
