// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import type { PluginRegistryEntry } from "@codevisor/api"
import { createFileRoute, Link } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import { PluginAvatar, registryBaseUrl } from "../components/plugin-directory"
import { SiteNav } from "../components/site-nav"

/// codevisor.dev/plugins — the public face of the plugin registry. Renders
/// the same index.json the in-app Browse sheet consumes, fetched server-side
/// in the route loader (SSR on the worker, hydrated on the client). The
/// registry lists every public GitHub repo tagged `codevisor-plugin` whose
/// manifest passes validation; entries always show the real repo owner.
///
/// The list stays scannable — artwork, name, one-line description, Install —
/// and each row links to /plugins/<id> for the full story (panes, tools,
/// repo facts, CLI install).

/// Exactly what the rows render, and nothing more — the loader payload must
/// be serializable, and the full registry entry carries opaque tool
/// inputSchema values that are not.
interface DirectoryEntry {
  readonly id: string
  readonly name: string
  readonly description?: string
  readonly repo: string
  readonly ownerAvatarUrl?: string
}

interface DirectoryData {
  /// Null when the registry was unreachable — distinct from an empty index,
  /// which is an honest "nothing published yet".
  readonly entries: ReadonlyArray<DirectoryEntry> | null
}

const toDirectoryEntry = (entry: PluginRegistryEntry): DirectoryEntry => ({
  id: entry.id,
  name: entry.name,
  ...(entry.description === undefined ? {} : { description: entry.description }),
  repo: entry.repo,
  ...(entry.ownerAvatarUrl === undefined ? {} : { ownerAvatarUrl: entry.ownerAvatarUrl })
})

const fetchDirectory = createServerFn({ method: "GET" }).handler(
  async (): Promise<DirectoryData> => {
    try {
      const response = await fetch(`${registryBaseUrl()}/plugins/index.json`, {
        signal: AbortSignal.timeout(10_000)
      })
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
      <SiteNav />

      <main className="mx-auto max-w-5xl px-6 pt-28 pb-16 sm:pt-32 sm:pb-24">
        <h1 className="text-4xl font-semibold tracking-[-0.035em] text-text">Plugin directory</h1>

        <section className="pt-12">
          {entries === null ? (
            <p className="text-lg text-muted">
              The plugin registry is unreachable right now. Try again in a few minutes.
            </p>
          ) : entries.length === 0 ? (
            <EmptyDirectory />
          ) : (
            <ul className="grid grid-cols-1 gap-x-10 gap-y-8 sm:grid-cols-2">
              {entries.map((entry) => (
                <PluginRow key={entry.id} entry={entry} />
              ))}
            </ul>
          )}
        </section>
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

/// One glanceable row per plugin: artwork, name, and what it does.
/// Everything else (version, repo, stars, capabilities) lives on the detail
/// page behind the row.
function PluginRow({ entry }: { entry: DirectoryEntry }) {
  return (
    <li className="flex items-center gap-4 rounded-xl border border-hairline bg-white/[0.03] p-4 transition-colors hover:bg-white/[0.05]">
      <Link
        to="/plugins/$pluginId"
        params={{ pluginId: entry.id }}
        className="group flex min-w-0 flex-1 items-center gap-4"
      >
        <PluginAvatar avatarUrl={entry.ownerAvatarUrl} sizeClass="size-12" />
        <span className="min-w-0">
          <span className="block truncate text-[16px] font-semibold text-text transition-colors group-hover:text-white">
            {entry.name}
          </span>
          <span className="block truncate text-[15px] text-muted">
            {entry.description !== undefined && entry.description.length > 0
              ? entry.description
              : entry.repo}
          </span>
        </span>
      </Link>
    </li>
  )
}
