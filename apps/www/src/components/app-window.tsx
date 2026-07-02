// A hand-built rendering of the HerdMan app window: sidebar of projects and
// machines, an agent chat, and the embedded terminal. Pure CSS — no
// screenshots — so it stays crisp at every size.
export function AppWindow() {
  return (
    <div className="relative mx-auto w-full max-w-5xl">
      {/* Ambient light behind the window */}
      <div
        aria-hidden
        className="absolute -inset-x-20 -top-24 -bottom-16 -z-10"
        style={{
          background:
            "radial-gradient(60% 55% at 50% 40%, rgba(74, 222, 128, 0.14) 0%, rgba(56, 189, 248, 0.08) 45%, transparent 75%)"
        }}
      />

      <div className="overflow-hidden rounded-2xl border border-white/10 bg-ink-raised shadow-[0_60px_120px_-40px_rgba(0,0,0,0.9)]">
        {/* Title bar */}
        <div className="flex items-center gap-2 border-b border-white/5 bg-white/[0.03] px-4 py-3">
          <span className="size-3 rounded-full bg-[#ff5f57]" />
          <span className="size-3 rounded-full bg-[#febc2e]" />
          <span className="size-3 rounded-full bg-[#28c840]" />
          <span className="ml-4 font-mono text-[11px] tracking-wide text-wool/60">
            HerdMan — api-gateway
          </span>
        </div>

        <div className="flex text-left">
          {/* Sidebar */}
          <div className="hidden w-56 shrink-0 flex-col gap-5 border-r border-white/5 bg-black/30 p-4 sm:flex">
            <div>
              <p className="mb-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-wool/50">
                Projects
              </p>
              <SidebarRow label="api-gateway" active />
              <SidebarRow label="mobile-app" />
              <SidebarRow label="infra" />
            </div>
            <div>
              <p className="mb-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-wool/50">
                Machines
              </p>
              <SidebarRow label="This Mac" dot="bg-mint" />
              <SidebarRow label="build-box.local" dot="bg-mint" />
              <SidebarRow label="gpu-rig" dot="bg-wool/40" />
            </div>
            <div>
              <p className="mb-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-wool/50">
                Harnesses
              </p>
              <SidebarRow label="Claude Code" dot="bg-mint" />
              <SidebarRow label="Codex" dot="bg-mint" />
            </div>
          </div>

          {/* Chat + terminal */}
          <div className="flex min-w-0 flex-1 flex-col">
            <div className="flex flex-1 flex-col gap-4 p-5">
              <ChatBubble author="You">
                Fix the flaky retry logic in the webhook worker, then run the tests.
              </ChatBubble>
              <ChatBubble author="Claude Code" agent>
                The retry loop in <Code>webhook/worker.ts</Code> re-queued on every error, including
                4xx. I scoped retries to network failures and 5xx with exponential backoff, and
                added a regression test.
              </ChatBubble>
              <div className="flex items-center gap-2 text-[12px] text-wool/60">
                <span className="inline-block size-1.5 animate-pulse rounded-full bg-mint" />
                Running <span className="font-mono text-wool">bun test</span> on build-box.local…
              </div>
            </div>

            {/* Terminal strip */}
            <div className="border-t border-white/5 bg-black/60 p-4 font-mono text-[12px] leading-relaxed">
              <p className="text-wool/50">$ bun test webhook</p>
              <p className="text-wool">
                <span className="text-mint">✓</span> retries network failures with backoff{" "}
                <span className="text-wool/40">(12ms)</span>
              </p>
              <p className="text-wool">
                <span className="text-mint">✓</span> does not retry 4xx responses{" "}
                <span className="text-wool/40">(4ms)</span>
              </p>
              <p className="text-cloud">
                14 pass, 0 fail <span className="animate-pulse text-mint">▌</span>
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

function SidebarRow({
  label,
  active = false,
  dot
}: {
  label: string
  active?: boolean
  dot?: string
}) {
  return (
    <div
      className={`flex items-center gap-2 rounded-md px-2 py-1.5 text-[13px] ${
        active ? "bg-white/10 text-cloud" : "text-wool"
      }`}
    >
      {dot ? <span className={`size-1.5 rounded-full ${dot}`} /> : null}
      {label}
    </div>
  )
}

function ChatBubble({
  author,
  agent = false,
  children
}: {
  author: string
  agent?: boolean
  children: React.ReactNode
}) {
  return (
    <div className="max-w-xl">
      <p className={`mb-1 text-[11px] font-semibold ${agent ? "text-mint" : "text-wool/60"}`}>
        {author}
      </p>
      <div
        className={`rounded-xl px-4 py-3 text-[13px] leading-relaxed ${
          agent ? "border border-white/5 bg-white/[0.04] text-cloud" : "bg-white/10 text-cloud"
        }`}
      >
        {children}
      </div>
    </div>
  )
}

function Code({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded bg-black/50 px-1.5 py-0.5 font-mono text-[12px] text-mint">
      {children}
    </span>
  )
}
