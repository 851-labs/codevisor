import { createFileRoute } from "@tanstack/react-router"

import { InstallCommand } from "../components/install-command"

export const Route = createFileRoute("/")({
  component: Home
})

function Home() {
  return (
    <div className="marketing-shell min-h-screen">
      <Nav />
      <main>
        <Hero />
        <Screenshot
          src="/screenshots/chat.png"
          alt="Codevisor running a Claude Code chat that fixes flaky webhook retries, with the conversation and code changes side by side"
        />
        <Feature
          title="A real terminal. Built in."
          body="Watch your agents work, or take the wheel yourself. Every chat has a terminal underneath it, right where the work happens."
          src="/screenshots/terminal.png"
          alt="Codevisor with the built-in terminal open under an agent chat"
        />
        <Feature
          title="Projects keep the thread."
          body="Point Codevisor at a folder and every conversation about that code lives together — including the agent chats you already had."
          src="/screenshots/new-chat.png"
          alt="Codevisor project view listing chats for the api-gateway project"
        />
        <TextFeatures />
        <Install />
      </main>
      <Footer />
    </div>
  )
}

function Nav() {
  return (
    <header className="fixed inset-x-0 top-0 z-40 border-b border-hairline bg-black/80 backdrop-blur-xl">
      <nav className="mx-auto flex h-11 max-w-5xl items-center justify-between px-6 text-xs">
        <a href="/" className="flex items-center gap-2 font-semibold tracking-tight text-text">
          <img src="/codevisor-icon.png" alt="" className="size-6 rounded" />
          Codevisor
        </a>
        <div className="flex items-center gap-6 text-muted">
          <a href="/docs" className="transition-colors hover:text-text">
            Docs
          </a>
          <a
            href="#install"
            className="rounded-full bg-text px-3 py-1 font-medium text-black transition-opacity hover:opacity-90"
          >
            Install
          </a>
        </div>
      </nav>
    </header>
  )
}

function Hero() {
  return (
    <section className="px-6 pt-32 pb-14 text-center sm:pt-40">
      <h1 className="mx-auto max-w-3xl text-5xl font-semibold tracking-tight text-balance sm:text-7xl">
        Every coding agent. One app.
      </h1>
      <p className="mx-auto mt-6 max-w-xl text-lg text-muted">
        Codevisor runs Claude Code, Codex, and any ACP agent on your machines — in one native macOS
        app.
      </p>
      <InstallCta placement="hero" />
    </section>
  )
}

function InstallCta({ placement }: { placement: "hero" | "footer" }) {
  return (
    <div className="mx-auto mt-8 w-full max-w-lg">
      <InstallCommand placement={placement} />
    </div>
  )
}

function Screenshot({ src, alt }: { src: string; alt: string }) {
  return (
    <div className="mx-auto max-w-5xl px-6">
      <img src={src} alt={alt} className="h-auto w-full" loading="lazy" />
    </div>
  )
}

function Feature({
  title,
  body,
  src,
  alt
}: {
  title: string
  body: string
  src: string
  alt: string
}) {
  return (
    <section className="pt-28 text-center sm:pt-36">
      <div className="mx-auto max-w-xl px-6">
        <h2 className="text-3xl font-semibold tracking-tight sm:text-5xl">{title}</h2>
        <p className="mt-4 text-lg text-muted">{body}</p>
      </div>
      <div className="mt-10">
        <Screenshot src={src} alt={alt} />
      </div>
    </section>
  )
}

function TextFeatures() {
  const items = [
    {
      title: "Local-first",
      body: "Your chats live in a database on your machine. No cloud in the middle."
    },
    {
      title: "Remote machines",
      body: "Run the server on a Linux box and pair it with a token. Everything syncs live."
    },
    {
      title: "Native",
      body: "Purpose-built downloads for Apple Silicon and Intel Macs — no fat binaries."
    },
    {
      title: "Self-updating",
      body: "The app and your remote servers keep themselves on the latest release."
    }
  ]
  return (
    <section className="mx-auto max-w-5xl px-6 pt-28 sm:pt-36">
      <div className="grid gap-x-12 gap-y-10 border-t border-hairline pt-12 sm:grid-cols-2">
        {items.map((item) => (
          <div key={item.title}>
            <h3 className="text-[15px] font-semibold">{item.title}</h3>
            <p className="mt-1.5 text-[15px] leading-relaxed text-muted">{item.body}</p>
          </div>
        ))}
      </div>
    </section>
  )
}

function Install() {
  return (
    <section id="install" className="px-6 pt-28 pb-32 text-center sm:pt-36">
      <h2 className="mx-auto max-w-3xl text-5xl font-semibold tracking-tight text-balance sm:text-7xl">
        Get Codevisor.
      </h2>
      <p className="mx-auto mt-6 max-w-xl text-lg text-muted">
        One command installs the app on a Mac and sets up the Codevisor server on Linux.
      </p>
      <InstallCta placement="footer" />
    </section>
  )
}

function Footer() {
  return (
    <footer className="border-t border-hairline px-6 py-10">
      <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-4 text-xs text-muted sm:flex-row">
        <span>© {new Date().getFullYear()} 851 Inc.</span>
        <a href="/install.sh" className="transition-colors hover:text-text">
          install.sh
        </a>
      </div>
    </footer>
  )
}
