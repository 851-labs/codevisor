import { cn } from "../lib/cn"

// Shimmering status text ("Thinking…", "Starting agent…"): a gradient swept
// across background-clipped text. Falls back to static muted text when the
// user prefers reduced motion.
export function ShimmerText({ children, className }: { children: string; className?: string }) {
  return (
    <span
      className={cn(
        "animate-shimmer bg-clip-text text-sm text-transparent",
        "bg-[linear-gradient(90deg,var(--muted-foreground)_40%,var(--foreground)_50%,var(--muted-foreground)_60%)] bg-[length:200%_100%]",
        "motion-reduce:text-muted-foreground motion-reduce:animate-none motion-reduce:bg-none",
        className
      )}
    >
      {children}
    </span>
  )
}
