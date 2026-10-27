export function PluginAvatar({
  avatarUrl,
  sizeClass
}: {
  avatarUrl: string | undefined
  sizeClass: string
}) {
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
