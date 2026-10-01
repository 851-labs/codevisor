import { createFileRoute } from "@tanstack/react-router"

import { InstallCommand } from "../components/install-command"
import { SiteFooter } from "../components/site-footer"
import { SiteNav } from "../components/site-nav"

export const Route = createFileRoute("/")({
  head: () => ({ meta: [{ name: "theme-color", content: "#000000" }] }),
  component: Home
})

function Home() {
  return (
    <div className="marketing-shell min-h-screen">
      <SiteNav />
      <main>
        <Hero />
        <DevicePair
          mac={{
            src: "/screenshots/mac-conversation.webp",
            alt: "Codevisor on Mac with a Claude Code chat that built a focus timer, and chats from projects on Studio Mac and Linux Server in the sidebar"
          }}
          iphone={{
            src: "/screenshots/iphone-conversation.webp",
            alt: "The same focus timer chat open in Codevisor on iPhone"
          }}
          eager
        />
        <Feature
          title="Start anywhere."
          body="Pick a machine, a project, and a model, then say what to build. Your Mac, a Mac mini in the closet, or a Linux box in the cloud — every machine on your account is one tap away."
          mac={{
            src: "/screenshots/mac-new-chat.webp",
            alt: "Codevisor's new chat page on Mac, targeting the daylight project on Studio Mac with Sonnet 4.6"
          }}
          iphone={{
            src: "/screenshots/iphone-new-chat.webp",
            alt: "Starting a new chat on iPhone, targeting the daylight project on Studio Mac"
          }}
        />
        <Feature
          title="See what your agent built."
          body="Open the dev server your agent just started in a built-in browser — even when it's running on another machine. No port forwarding, no tunnels to set up."
          mac={{
            src: "/screenshots/mac-browser.webp",
            alt: "The Daylight focus timer app running at localhost:3000 in Codevisor's built-in browser on Mac"
          }}
          iphone={{
            src: "/screenshots/iphone-browser.webp",
            alt: "The same localhost:3000 preview open in Codevisor on iPhone"
          }}
        />
        <Pocket />
        <TextFeatures />
        <Install />
      </main>
      <SiteFooter />
    </div>
  )
}

function Hero() {
  return (
    <section className="px-6 pt-32 pb-14 text-center sm:pt-40">
      <h1 className="mx-auto max-w-3xl text-5xl font-semibold tracking-tight text-balance sm:text-7xl">
        Every coding agent. One app.
      </h1>
      <p className="mx-auto mt-6 max-w-xl text-lg text-muted">
        Run Claude Code, Codex, Pi, and any ACP agent on your Macs and Linux servers — from native
        apps for Mac and iPhone.
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

type Shot = { src: string; alt: string }

/// A raw iPhone screen capture (1284 × 2778) inside a thin black bezel. The
/// elliptical radii keep the display's corner curve at any rendered width.
function IPhone({ src, alt, eager }: Shot & { eager?: boolean }) {
  return (
    <div className="rounded-[15%/7%] bg-black p-[3%] shadow-2xl ring-1 ring-white/15">
      <img
        src={src}
        alt={alt}
        width={1284}
        height={2778}
        className="h-auto w-full rounded-[12.4%/5.73%]"
        loading={eager ? "eager" : "lazy"}
      />
    </div>
  )
}

/// A Mac window capture with its iPhone counterpart overlapping the bottom
/// right corner, so every scene shows both apps. Phone-sized screens show only
/// the iPhone capture at a readable size; a shrunken Mac window would be
/// illegible there. Hidden lazy images are never fetched.
function DevicePair({ mac, iphone, eager }: { mac: Shot; iphone: Shot; eager?: boolean }) {
  return (
    <div className="mx-auto max-w-5xl px-6">
      <div className="relative md:pr-[9%] md:pb-[7%]">
        <img
          src={mac.src}
          alt={mac.alt}
          width={2560}
          height={1640}
          className="hidden h-auto w-full md:block"
          loading="lazy"
        />
        <div className="mx-auto w-64 md:absolute md:right-0 md:bottom-0 md:w-[23%]">
          <IPhone {...iphone} eager={eager} />
        </div>
      </div>
    </div>
  )
}

function Feature({
  title,
  body,
  mac,
  iphone
}: {
  title: string
  body: string
  mac: Shot
  iphone: Shot
}) {
  return (
    <section className="pt-28 text-center sm:pt-36">
      <div className="mx-auto max-w-xl px-6">
        <h2 className="text-3xl font-semibold tracking-tight sm:text-5xl">{title}</h2>
        <p className="mt-4 text-lg text-muted">{body}</p>
      </div>
      <div className="mt-10">
        <DevicePair mac={mac} iphone={iphone} />
      </div>
    </section>
  )
}

function Pocket() {
  return (
    <section className="mx-auto grid max-w-5xl items-center gap-12 px-6 pt-28 sm:pt-36 md:grid-cols-[1fr_auto]">
      <div className="text-center md:text-left">
        <h2 className="text-3xl font-semibold tracking-tight sm:text-5xl">
          Your agents, in your pocket.
        </h2>
        <p className="mt-4 max-w-md text-lg text-muted max-md:mx-auto">
          The iPhone app shows every project on every machine, so you can check on a long run,
          answer an agent's question, or kick off the next task from anywhere. Adding a new machine
          is as easy as scanning its QR code.
        </p>
      </div>
      <div className="mx-auto w-64">
        <IPhone
          src="/screenshots/iphone-projects.webp"
          alt="Codevisor on iPhone listing chats, browser previews, and terminals across projects on Studio Mac and Linux Server"
        />
      </div>
    </section>
  )
}

function TextFeatures() {
  const items = [
    {
      title: "Your machines, your data",
      body: "Agents run on your hardware, and chats are stored on the machine that ran them. Nothing is stuck in someone else's cloud."
    },
    {
      title: "A real terminal",
      body: "Every project gets an embedded Ghostty terminal, right next to the agents working in it."
    },
    {
      title: "Native, not Electron",
      body: "Pure Swift apps built for Apple silicon and iPhone. Fast to launch, light on memory."
    },
    {
      title: "Always up to date",
      body: "The Mac app and your remote servers keep themselves on the latest release."
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
