import { createFileRoute } from "@tanstack/react-router"

import { SiteFooter } from "../components/site-footer"
import { SiteNav } from "../components/site-nav"

export const Route = createFileRoute("/support")({
  head: () => ({
    meta: [
      { title: "Support — Codevisor" },
      { name: "description", content: "Get help with Codevisor. Email hello@codevisor.dev." },
      { name: "theme-color", content: "#000000" }
    ]
  }),
  component: Support
})

function Support() {
  return (
    <div className="marketing-shell flex min-h-screen flex-col">
      <SiteNav />
      <main className="mx-auto w-full max-w-5xl flex-1 px-6 pt-32 pb-24 sm:pt-40">
        <h1 className="text-5xl font-semibold tracking-tight sm:text-7xl">Support</h1>
        <p className="mt-6 text-lg text-muted">Need a hand? Send us an email.</p>
        <a
          href="mailto:hello@codevisor.dev"
          className="mt-6 inline-flex min-h-11 items-center text-xl text-text underline decoration-white/30 underline-offset-8 transition-colors hover:decoration-white focus-visible:outline-2 focus-visible:outline-offset-8 focus-visible:outline-text"
        >
          hello@codevisor.dev
        </a>
      </main>
      <SiteFooter />
    </div>
  )
}
