import type { ReactNode } from "react"

import { SectionHead } from "./section-head"

function WorktreeCard({
  title,
  body,
  children
}: {
  title: string
  body: string
  children: ReactNode
}) {
  return (
    <div>
      <div
        className="flex aspect-[4/3] flex-col overflow-hidden rounded-(--landing-card-radius) border border-hairline bg-surface p-4 sm:aspect-[16/10]"
        aria-hidden
      >
        {children}
      </div>
      <h3 className="mt-4 text-[15px] font-medium">{title}</h3>
      <p className="mt-1 text-[13px] leading-relaxed text-muted">{body}</p>
    </div>
  )
}

const WORKSPACES = [
  ["garlic", "Claude Code", "Done"],
  ["basil", "Codex", "Running"],
  ["fennel", "Pi", "Running"],
  ["sorrel", "OpenCode", "Needs you"]
]

const DIFF_MODES = ["Last Turn", "Uncommitted", "Staged", "Unstaged", "Branch"]

export function Worktrees() {
  return (
    <section className="border-b border-hairline px-5 py-20 sm:px-8">
      <SectionHead eyebrow="Worktrees" title="Give every chat its own worktree." />
      <div className="mt-10 grid gap-x-6 gap-y-10 md:grid-cols-2">
        <WorktreeCard
          title="Start in a new worktree"
          body="Pick the machine, project, agent, and model, then run in the project directory or a fresh worktree on its own branch."
        >
          <div className="m-auto w-full max-w-[300px] rounded-lg border border-hairline bg-page p-1.5 text-[12px] shadow-xl">
            <p className="px-2 py-1 text-[11px] text-muted">Run in</p>
            <p className="rounded-md px-2 py-1.5">Project directory</p>
            <p className="flex items-center justify-between rounded-md bg-signal px-2 py-1.5 text-white">
              New worktree <span>✓</span>
            </p>
          </div>
        </WorktreeCard>
        <WorktreeCard
          title="Mix agents in one repo"
          body="Claude Code in one workspace, Codex in the next. Nobody steps on anybody's changes."
        >
          <div className="my-auto space-y-1.5 font-mono text-[11px]">
            {WORKSPACES.map(([name, agent, state]) => (
              <div
                key={name}
                className="flex items-center gap-3 rounded-md border border-hairline bg-page px-3 py-2"
              >
                <span
                  className={`size-1.5 rounded-full ${state === "Done" ? "bg-go" : "bg-signal"}`}
                />
                <span>codevisor/{name}</span>
                <span className="ml-auto text-muted">{agent}</span>
              </div>
            ))}
          </div>
        </WorktreeCard>
        <WorktreeCard
          title="Review every change"
          body="See the last turn, what's uncommitted, staged, or the whole branch against its base, and the PR's checks right in the sidebar."
        >
          <div className="flex flex-wrap gap-1 text-[11px]">
            {DIFF_MODES.map((mode, index) => (
              <span
                key={mode}
                className={`rounded-md px-2 py-1 ${index === 0 ? "bg-raised font-medium" : "text-muted"}`}
              >
                {mode}
              </span>
            ))}
          </div>
          <pre className="mt-auto rounded-md border border-hairline bg-page px-3 py-2.5 font-mono text-[11px] leading-relaxed">
            <span className="text-muted">@@ src/search.ts</span>
            {"\n"}
            <span className="text-[light-dark(#c4262e,#ff7b7b)]">- return []</span>
            {"\n"}
            <span className="text-go">+ return index.query(q)</span>
          </pre>
        </WorktreeCard>
        <WorktreeCard
          title="Archive, then restore"
          body="Done with a workspace? Archive it. Codevisor saves a git snapshot first, so you can bring it back."
        >
          <div className="m-auto w-full max-w-[260px] rounded-lg border border-hairline bg-page p-1.5 text-[12px] shadow-xl">
            <p className="rounded-md px-2 py-1.5">Rename Workspace</p>
            <p className="rounded-md bg-raised px-2 py-1.5">Archive workspace</p>
            <div className="my-1 h-px bg-hairline" />
            <p className="rounded-md px-2 py-1.5 text-muted">Restore workspace</p>
          </div>
        </WorktreeCard>
      </div>
    </section>
  )
}
