import type { BranchDiffTotals } from "@herdman/api"

export function DiffCounter({ totals }: { totals: BranchDiffTotals }) {
  return (
    <span className="shrink-0 font-mono text-xs tabular-nums">
      <span className="text-[var(--herdman-diff-add-fg)]">+{totals.added}</span>{" "}
      <span className="text-[var(--herdman-diff-del-fg)]">−{totals.removed}</span>
    </span>
  )
}
