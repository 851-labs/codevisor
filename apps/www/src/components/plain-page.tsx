import type { ReactNode } from "react"

export const plainLinkClass =
  "text-text underline decoration-hairline underline-offset-4 transition-colors hover:decoration-current"

export function PlainPage({ children }: { children: ReactNode }) {
  return (
    <main className="marketing-shell min-h-screen px-6 py-24">
      <div className="mx-auto max-w-2xl space-y-4 text-[17px] text-muted">{children}</div>
    </main>
  )
}
