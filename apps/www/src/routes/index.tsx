import { createFileRoute } from "@tanstack/react-router"

import { AppWindow } from "../components/app-window"
import { CopyCommand } from "../components/copy-command"
import { Reveal } from "../components/reveal"

export const Route = createFileRoute("/")({
  component: Home
})

const INSTALL_CMD = "curl -fsSL https://www.herdman.dev/install.sh | sh"

function Home() {
  return (
    <>
      <Nav />
      <main className="overflow-x-clip">
        <Hero />
        <section id="features" className="mx-auto max-w-6xl px-6">
          <FeatureHarnesses />
          <FeatureTerminal />
          <FeatureMachines />
          <FeatureProjects />
          <FeatureGrid />
        </section>
        <InstallSection />
      </main>
      <Footer />
    </>
  )
}

function SheepMark({ className = "size-6" }: { className?: string }) {
  return <img src="/sheep.svg" alt="" className={className} />
}

function Nav() {
  return (
    <header className="fixed inset-x-0 top-0 z-40 border-b border-white/5 bg-ink/70 backdrop-blur-xl">
      <nav className="mx-auto flex h-12 max-w-6xl items-center justify-between px-6">
        <a href="/" className="flex items-center gap-2 text-sm font-semibold tracking-tight">
          <SheepMark className="size-5" />
          HerdMan
        </a>
        <div className="flex items-center gap-6 text-[13px] text-wool">
          <a href="#features" className="transition-colors hover:text-cloud">
            Features
          </a>
          <a href="#install" className="transition-colors hover:text-cloud">
            Install
          </a>
          <a
            href="/download/macos"
            className="rounded-full bg-cloud px-3.5 py-1 font-semibold text-ink transition-transform hover:scale-[1.03]"
          >
            Download
          </a>
        </div>
      </nav>
    </header>
  )
}

function Hero() {
  return (
    <section className="relative px-6 pt-36 pb-24 text-center sm:pt-44">
      {/* Aurora glow */}
      <div
        aria-hidden
        className="absolute inset-x-0 top-0 -z-10 h-[640px]"
        style={{
          background:
            "radial-gradient(50% 60% at 50% 0%, rgba(163, 230, 53, 0.10) 0%, rgba(56, 189, 248, 0.06) 50%, transparent 80%)"
        }}
      />

      <div className="animate-rise" style={{ animationDelay: "0ms" }}>
        <SheepMark className="mx-auto mb-8 size-14 opacity-90" />
      </div>

      <h1
        className="animate-rise mx-auto max-w-4xl text-[clamp(3rem,9vw,6.5rem)] leading-[0.95] font-extrabold tracking-[-0.03em]"
        style={{ animationDelay: "80ms" }}
      >
        Every agent.
        <br />
        <span className="text-meadow-gradient">One flock.</span>
      </h1>

      <p
        className="animate-rise mx-auto mt-8 max-w-xl text-lg leading-relaxed text-wool sm:text-xl"
        style={{ animationDelay: "160ms" }}
      >
        HerdMan runs Claude Code, Codex, and every ACP coding agent on your machines — in one native
        macOS app.
      </p>

      <div
        className="animate-rise mt-10 flex flex-col items-center gap-4"
        style={{ animationDelay: "240ms" }}
      >
        <a
          href="/download/macos"
          className="rounded-full bg-cloud px-8 py-3.5 text-[15px] font-semibold text-ink shadow-[0_0_40px_rgba(245,245,247,0.15)] transition-transform hover:scale-[1.04]"
        >
          Download for macOS
        </a>
        <p className="text-[13px] text-wool/60">
          Free · Apple Silicon &amp; Intel ·{" "}
          <a
            href="#install"
            className="underline decoration-wool/30 underline-offset-4 hover:text-wool"
          >
            or install with one command
          </a>
        </p>
      </div>

      <div className="animate-rise mt-20" style={{ animationDelay: "360ms" }}>
        <AppWindow />
      </div>
    </section>
  )
}

function SectionHeading({
  eyebrow,
  children,
  align = "left"
}: {
  eyebrow: string
  children: React.ReactNode
  align?: "left" | "center"
}) {
  return (
    <div className={align === "center" ? "text-center" : ""}>
      <p className="mb-3 text-[13px] font-semibold tracking-[0.2em] text-mint uppercase">
        {eyebrow}
      </p>
      <h2 className="max-w-2xl text-[clamp(2rem,5vw,3.5rem)] leading-[1.02] font-extrabold tracking-[-0.02em]">
        {children}
      </h2>
    </div>
  )
}

function FeatureHarnesses() {
  return (
    <div className="grid items-center gap-12 py-28 lg:grid-cols-2">
      <Reveal>
        <SectionHeading eyebrow="Harnesses">
          All your harnesses. <span className="text-meadow-gradient">One home.</span>
        </SectionHeading>
        <p className="mt-6 max-w-md text-lg leading-relaxed text-wool">
          HerdMan finds the ACP agents already installed on your computer and brings them into one
          place. Turn on the ones you want, switch between them mid-project, and keep every
          conversation.
        </p>
      </Reveal>
      <Reveal delay={120}>
        <div className="flex flex-col gap-3">
          {[
            { name: "Claude Code", status: "Detected · enabled" },
            { name: "Codex", status: "Detected · enabled" },
            { name: "Any ACP agent", status: "Install it, HerdMan finds it" }
          ].map((h) => (
            <div
              key={h.name}
              className="flex items-center justify-between rounded-2xl border border-ink-border bg-ink-raised px-6 py-5 transition-colors hover:border-mint/30"
            >
              <span className="text-lg font-semibold">{h.name}</span>
              <span className="text-[13px] text-wool/70">{h.status}</span>
            </div>
          ))}
        </div>
      </Reveal>
    </div>
  )
}

function FeatureTerminal() {
  return (
    <div className="grid items-center gap-12 py-28 lg:grid-cols-2">
      <Reveal className="order-2 lg:order-1" delay={120}>
        <div className="overflow-hidden rounded-2xl border border-ink-border bg-black/70 font-mono text-[13px] leading-relaxed shadow-[0_40px_80px_-40px_rgba(0,0,0,0.8)]">
          <div className="flex items-center gap-2 border-b border-white/5 px-4 py-2.5 text-[11px] text-wool/50">
            <span className="size-2.5 rounded-full bg-[#ff5f57]" />
            <span className="size-2.5 rounded-full bg-[#febc2e]" />
            <span className="size-2.5 rounded-full bg-[#28c840]" />
            <span className="ml-2">zsh — api-gateway</span>
          </div>
          <div className="p-5">
            <p className="text-wool/60">$ git diff --stat</p>
            <p className="text-wool">webhook/worker.ts | 41 ++++++----</p>
            <p className="text-wool">webhook/worker.test.ts | 58 ++++++++++++</p>
            <p className="mt-2 text-wool/60">$ bun test webhook</p>
            <p className="text-cloud">
              <span className="text-mint">14 pass</span>, 0 fail{" "}
              <span className="animate-pulse text-mint">▌</span>
            </p>
          </div>
        </div>
      </Reveal>
      <Reveal className="order-1 lg:order-2">
        <SectionHeading eyebrow="Terminal">
          A real terminal. <span className="text-meadow-gradient">Built in.</span>
        </SectionHeading>
        <p className="mt-6 max-w-md text-lg leading-relaxed text-wool">
          Powered by Ghostty, the terminal lives right next to the conversation. Watch your agents
          work, drop into a shell when you want your hands on the wheel, and never leave the app.
        </p>
      </Reveal>
    </div>
  )
}

function FeatureMachines() {
  return (
    <div className="grid items-center gap-12 py-28 lg:grid-cols-2">
      <Reveal>
        <SectionHeading eyebrow="Machines">
          Herd every machine <span className="text-meadow-gradient">you own.</span>
        </SectionHeading>
        <p className="mt-6 max-w-md text-lg leading-relaxed text-wool">
          Run the HerdMan server on your Linux box, your build machine, or that Mac mini in the
          closet. Pair it with a token, and every chat, project, and session syncs live to your
          desktop.
        </p>
      </Reveal>
      <Reveal delay={120}>
        <div className="flex flex-col gap-3">
          {[
            { name: "This Mac", detail: "Local · always on", online: true },
            { name: "build-box.local", detail: "Linux · paired", online: true },
            { name: "gpu-rig", detail: "Linux · paired", online: true }
          ].map((m) => (
            <div
              key={m.name}
              className="flex items-center gap-4 rounded-2xl border border-ink-border bg-ink-raised px-6 py-5"
            >
              <span className={`size-2 rounded-full ${m.online ? "bg-mint" : "bg-wool/40"}`} />
              <span className="flex-1 font-mono text-[15px]">{m.name}</span>
              <span className="text-[13px] text-wool/70">{m.detail}</span>
            </div>
          ))}
        </div>
      </Reveal>
    </div>
  )
}

function FeatureProjects() {
  return (
    <div className="py-28 text-center">
      <Reveal>
        <SectionHeading eyebrow="Projects" align="center">
          <span className="text-meadow-gradient">Projects</span> that keep the thread.
        </SectionHeading>
        <p className="mx-auto mt-6 max-w-xl text-lg leading-relaxed text-wool">
          Pick a folder and HerdMan opens a chat scoped to that project — and pulls in the agent
          conversations you already had there. Your context follows the code, not the other way
          around.
        </p>
      </Reveal>
    </div>
  )
}

function FeatureGrid() {
  const items = [
    {
      title: "Native, truly",
      body: "A SwiftUI app that feels at home on macOS — menu bar commands, keyboard-first, fast."
    },
    {
      title: "Local-first",
      body: "Your chats live in a local database on your machines. No cloud middleman."
    },
    {
      title: "Universal",
      body: "One download for Apple Silicon and Intel, with native runtimes for both."
    },
    {
      title: "Self-updating",
      body: "The app and your remote servers quietly keep themselves on the latest release."
    }
  ]
  return (
    <div className="grid gap-4 pb-28 sm:grid-cols-2">
      {items.map((item, i) => (
        <Reveal key={item.title} delay={i * 80}>
          <div className="h-full rounded-2xl border border-ink-border bg-ink-raised p-7 transition-colors hover:border-mint/30">
            <h3 className="text-lg font-bold">{item.title}</h3>
            <p className="mt-2 text-[15px] leading-relaxed text-wool">{item.body}</p>
          </div>
        </Reveal>
      ))}
    </div>
  )
}

function InstallSection() {
  return (
    <section id="install" className="relative border-t border-white/5 bg-black/40 px-6 py-28">
      <div className="mx-auto max-w-6xl">
        <Reveal>
          <SectionHeading eyebrow="Install" align="center">
            In your dock in <span className="text-meadow-gradient">under a minute.</span>
          </SectionHeading>
        </Reveal>

        <div className="mt-16 grid gap-6 lg:grid-cols-2">
          <Reveal delay={80}>
            <div className="flex h-full flex-col rounded-3xl border border-ink-border bg-ink-raised p-8">
              <p className="text-[13px] font-semibold tracking-[0.2em] text-mint uppercase">
                macOS
              </p>
              <h3 className="mt-3 text-2xl font-bold">The app</h3>
              <p className="mt-3 flex-1 text-[15px] leading-relaxed text-wool">
                Download the disk image, drag HerdMan to Applications, done. Signed and notarized —
                no Homebrew required.
              </p>
              <div className="mt-6 flex flex-col gap-3">
                <a
                  href="/download/macos"
                  className="rounded-full bg-cloud px-6 py-3 text-center text-[15px] font-semibold text-ink transition-transform hover:scale-[1.02]"
                >
                  Download HerdMan
                </a>
                <p className="text-center text-[12px] text-wool/50">
                  Prefer Homebrew?{" "}
                  <span className="font-mono text-wool">
                    brew install --cask 851-labs/tap/herdman
                  </span>
                </p>
              </div>
            </div>
          </Reveal>

          <Reveal delay={160}>
            <div className="flex h-full flex-col rounded-3xl border border-ink-border bg-ink-raised p-8">
              <p className="text-[13px] font-semibold tracking-[0.2em] text-sky uppercase">
                macOS &amp; Linux
              </p>
              <h3 className="mt-3 text-2xl font-bold">One command</h3>
              <p className="mt-3 flex-1 text-[15px] leading-relaxed text-wool">
                One script for the whole flock: on a Mac it installs the app; on Linux it installs
                the HerdMan server, sets it up as a service, and gets it ready to pair with your
                desktop.
              </p>
              <div className="mt-6">
                <CopyCommand command={INSTALL_CMD} />
              </div>
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  )
}

function Footer() {
  return (
    <footer className="border-t border-white/5 px-6 py-12">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-6 text-[13px] text-wool/60 sm:flex-row">
        <div className="flex items-center gap-2">
          <SheepMark className="size-4 opacity-60" />
          <span>© {new Date().getFullYear()} 851 Labs, LLC</span>
        </div>
        <div className="flex items-center gap-6">
          <a href="/download/macos" className="transition-colors hover:text-cloud">
            Download
          </a>
          <a href="/install.sh" className="transition-colors hover:text-cloud">
            install.sh
          </a>
        </div>
      </div>
    </footer>
  )
}
