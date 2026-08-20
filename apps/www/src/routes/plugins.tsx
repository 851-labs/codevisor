// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import type { PluginRegistryEntry } from "@codevisor/api"
import { createFileRoute } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import { useState } from "react"

/// codevisor.dev/plugins — the public face of the plugin registry. Renders
/// the same index.json the in-app Browse sheet consumes, fetched server-side
/// in the route loader (SSR on the worker, hydrated on the client). The
/// registry lists every public GitHub repo tagged `codevisor-plugin` whose
/// manifest passes validation; entries always show the real repo owner.

const REGISTRY_INDEX_URL = "https://cloud.codevisor.dev/plugins/index.json"

/// Exactly what the cards render, and nothing more — the loader payload must
/// be serializable, and the full registry entry carries opaque tool
/// inputSchema values that are not.
interface DirectoryEntry {
  readonly id: string
  readonly name: string
  readonly version: string
  readonly description?: string
  readonly repo: string
  readonly stars: number
  readonly paneCount: number
  readonly toolCount: number
  readonly verified?: boolean
}

interface DirectoryData {
  /// Null when the registry was unreachable — distinct from an empty index,
  /// which is an honest "nothing published yet".
  readonly entries: ReadonlyArray<DirectoryEntry> | null
}

const toDirectoryEntry = (entry: PluginRegistryEntry): DirectoryEntry => ({
  id: entry.id,
  name: entry.name,
  version: entry.version,
  ...(entry.description === undefined ? {} : { description: entry.description }),
  repo: entry.repo,
  stars: entry.stars,
  paneCount: entry.panes.length,
  toolCount: entry.tools?.length ?? 0,
  ...(entry.verified === undefined ? {} : { verified: entry.verified })
})

const fetchDirectory = createServerFn({ method: "GET" }).handler(
  async (): Promise<DirectoryData> => {
    try {
      const response = await fetch(REGISTRY_INDEX_URL, { signal: AbortSignal.timeout(10_000) })
      if (!response.ok) return { entries: null }
      const index = (await response.json()) as { entries?: ReadonlyArray<PluginRegistryEntry> }
      return { entries: (index.entries ?? []).map(toDirectoryEntry) }
    } catch {
      return { entries: null }
    }
  }
)

export const Route = createFileRoute("/plugins")({
  loader: () => fetchDirectory(),
  head: () => ({
    meta: [
      { title: "Plugins — Codevisor" },
      {
        name: "description",
        content:
          "Browse Codevisor plugins: custom panes and agent tools served from your own machine. Publish yours by tagging a public GitHub repo with the codevisor-plugin topic."
      }
    ]
  }),
  component: PluginsDirectory
})

function PluginsDirectory() {
  const { entries } = Route.useLoaderData()
  return (
    <div className="marketing-shell min-h-screen">
      <header className="border-b border-hairline">
        <nav className="mx-auto flex h-14 max-w-5xl items-center justify-between px-6 text-sm">
          <a href="/" className="flex items-center gap-2 font-semibold tracking-tight text-text">
            <img src="/codevisor-icon.png" alt="" className="size-7 rounded-md" />
            Codevisor
          </a>
          <a href="/" className="text-muted transition-colors hover:text-text">
            Back to Codevisor
          </a>
        </nav>
      </header>

      <main className="mx-auto max-w-5xl px-6 py-16 sm:py-24">
        <div className="border-b border-hairline pb-12">
          <p className="text-xs font-medium tracking-[0.18em] text-muted uppercase">
            Plugin directory
          </p>
          <h1 className="mt-5 max-w-3xl text-4xl font-semibold tracking-[-0.035em] text-text sm:text-6xl">
            Plugins.
          </h1>
          <p className="mt-5 max-w-2xl text-lg leading-relaxed text-muted">
            Custom panes and agent tools for Codevisor, served from your own machine. Install any of
            these from Settings ▸ Plugins ▸ Browse, or with one command — Codevisor always shows the
            exact commands a plugin will run before anything executes.
          </p>
        </div>

        <section className="pt-12">
          {entries === null ? (
            <p className="text-lg text-muted">
              The plugin registry is unreachable right now. Try again in a few minutes.
            </p>
          ) : entries.length === 0 ? (
            <EmptyDirectory />
          ) : (
            <ul className="grid gap-6 sm:grid-cols-2">
              {entries.map((entry) => (
                <PluginCard key={entry.id} entry={entry} />
              ))}
            </ul>
          )}
        </section>

        <PublishCallout />
      </main>
    </div>
  )
}

function EmptyDirectory() {
  return (
    <div className="text-lg text-muted">
      <p>No plugins have been published yet.</p>
      <p className="mt-2">
        Yours could be first — tag a public GitHub repo with the{" "}
        <code className="font-mono text-[0.9em] text-text">codevisor-plugin</code> topic and it
        appears here within about 15 minutes.
      </p>
    </div>
  )
}

function PluginCard({ entry }: { entry: DirectoryEntry }) {
  return (
    <li className="flex flex-col rounded-xl border border-hairline bg-white/[0.04] p-5">
      <div className="flex items-baseline gap-2">
        <h2 className="text-[17px] font-semibold text-text">{entry.name}</h2>
        <span className="font-mono text-xs text-muted">{entry.version}</span>
        {entry.verified === true && (
          <span className="rounded-full border border-hairline px-2 py-0.5 text-[11px] text-muted">
            Verified
          </span>
        )}
      </div>
      <p className="mt-1 text-sm text-muted">
        <a
          href={`https://github.com/${entry.repo}`}
          className="transition-colors hover:text-text"
          rel="noopener"
        >
          {entry.repo}
        </a>
        {" · "}
        {capabilitySummary(entry)}
      </p>
      {entry.description !== undefined && entry.description.length > 0 && (
        <p className="mt-3 text-[15px] leading-relaxed text-muted">{entry.description}</p>
      )}
      <div className="mt-auto pt-4">
        <InstallLine repo={entry.repo} />
      </div>
    </li>
  )
}

/// "2 panes · 1 agent tool · 12 stars" — what installing adds, plus the
/// GitHub stars that anchor the entry's reputation.
function capabilitySummary(entry: DirectoryEntry): string {
  const parts: Array<string> = []
  if (entry.paneCount > 0) {
    parts.push(`${entry.paneCount} pane${entry.paneCount === 1 ? "" : "s"}`)
  }
  if (entry.toolCount > 0) {
    parts.push(`${entry.toolCount} agent tool${entry.toolCount === 1 ? "" : "s"}`)
  }
  parts.push(`${entry.stars} star${entry.stars === 1 ? "" : "s"}`)
  return parts.join(" · ")
}

function InstallLine({ repo }: { repo: string }) {
  const command = `codevisor plugin install ${repo}`
  const [copied, setCopied] = useState(false)
  const copy = () => {
    void navigator.clipboard.writeText(command).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    })
  }
  return (
    <button
      type="button"
      onClick={copy}
      className="flex w-full items-center gap-3 rounded-lg border border-hairline px-3 py-2.5 text-left font-mono text-[12px] text-muted transition-colors hover:text-text"
      aria-label={`Copy command: ${command}`}
    >
      <span className="flex-1 overflow-x-auto whitespace-nowrap">{command}</span>
      <span className="shrink-0 text-[10px] tracking-widest uppercase opacity-60">
        {copied ? "copied" : "copy"}
      </span>
    </button>
  )
}

function PublishCallout() {
  return (
    <section className="mt-16 border-t border-hairline pt-12">
      <h2 className="text-2xl font-semibold tracking-tight text-text">Publish your plugin.</h2>
      <p className="mt-3 max-w-2xl text-[15px] leading-relaxed text-muted">
        A Codevisor plugin is a public GitHub repo with a{" "}
        <code className="font-mono text-[0.9em] text-text">codevisor-plugin.json</code> manifest at
        its root, namespaced under your GitHub username. Add the{" "}
        <code className="font-mono text-[0.9em] text-text">codevisor-plugin</code> topic to the repo
        and the registry lists it within about 15 minutes; remove the topic to delist it. In the
        app, ask any agent to “make me a Codevisor plugin” — the authoring skill walks it through
        the whole contract.
      </p>
    </section>
  )
}
