import type { BranchDiffTotals } from "@codevisor/api"

export function DiffCounter({ totals }: { totals: BranchDiffTotals }) {
  return (
    <span className="shrink-0 font-mono text-xs tabular-nums">
      <span className="text-[var(--codevisor-diff-add-fg)]">+{totals.added}</span>{" "}
      <span className="text-[var(--codevisor-diff-del-fg)]">−{totals.removed}</span>
    </span>
  )
}
