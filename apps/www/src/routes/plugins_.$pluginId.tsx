// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import type { PluginRegistryEntry } from "@codevisor/api"
import { createFileRoute, Link } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import type { ReactNode } from "react"
import {
  CopyInstallCommand,
  InstallButton,
  PluginAvatar,
  registryBaseUrl
} from "../components/plugin-directory"
import { SiteNav } from "../components/site-nav"

/// codevisor.dev/plugins/<id> — everything the directory row leaves out,
/// rendered from the registry's per-plugin document (/plugins/<id>.json):
/// what installing adds (panes, agent tools) and the GitHub facts that anchor
/// the entry to a real owner. Install deep-links into the app's
/// discover→consent flow; the CLI command is the no-app fallback.

/// The serializable subset the page renders — the full registry entry
/// carries opaque tool inputSchema values that are not serializable.
interface PluginDetail {
  readonly id: string
  readonly name: string
  readonly version: string
  readonly description?: string
  readonly repo: string
  readonly ownerAvatarUrl?: string
  readonly stars: number
  readonly pushedAt: string
  readonly panes: ReadonlyArray<{ readonly type: string; readonly title: string }>
  readonly tools: ReadonlyArray<{ readonly name: string; readonly description: string }>
  readonly verified?: boolean
}

interface PluginDetailData {
  /// "missing" is a real 404 (unknown or delisted plugin); null means the
  /// registry itself was unreachable.
  readonly plugin: PluginDetail | "missing" | null
}

/// Plugin ids are always lowercase `owner.name` — anything else can skip the
/// network round trip (and never reaches the registry URL).
const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/

const toDetail = (entry: PluginRegistryEntry): PluginDetail => ({
  id: entry.id,
  name: entry.name,
  version: entry.version,
  ...(entry.description === undefined ? {} : { description: entry.description }),
  repo: entry.repo,
  ...(entry.ownerAvatarUrl === undefined ? {} : { ownerAvatarUrl: entry.ownerAvatarUrl }),
  stars: entry.stars,
  pushedAt: entry.pushedAt,
  panes: entry.panes.map((pane) => ({ type: pane.type, title: pane.title })),
  tools: (entry.tools ?? []).map((tool) => ({ name: tool.name, description: tool.description })),
  ...(entry.verified === undefined ? {} : { verified: entry.verified })
})

const fetchPlugin = createServerFn({ method: "GET" })
  .validator((pluginId: string) => pluginId)
  .handler(async ({ data: pluginId }): Promise<PluginDetailData> => {
    if (!PLUGIN_ID_PATTERN.test(pluginId)) return { plugin: "missing" }
    try {
      const response = await fetch(
        `${registryBaseUrl()}/plugins/${encodeURIComponent(pluginId)}.json`,
        { signal: AbortSignal.timeout(10_000) }
      )
      if (response.status === 404) return { plugin: "missing" }
      if (!response.ok) return { plugin: null }
      return { plugin: toDetail((await response.json()) as PluginRegistryEntry) }
    } catch {
      return { plugin: null }
    }
  })

export const Route = createFileRoute("/plugins_/$pluginId")({
  loader: ({ params }) => fetchPlugin({ data: params.pluginId }),
  head: (ctx) => {
    const plugin = ctx.loaderData?.plugin
    const name = typeof plugin === "object" && plugin !== null ? plugin.name : "Plugin"
    return {
      meta: [
        { title: `${name} — Codevisor Plugins` },
        ...(typeof plugin === "object" && plugin !== null && plugin.description !== undefined
          ? [{ name: "description", content: plugin.description }]
          : [])
      ]
    }
  },
  component: PluginDetailPage
})

function PluginDetailPage() {
  const { plugin } = Route.useLoaderData()
  return (
    <div className="marketing-shell min-h-screen">
      <SiteNav />
      <main className="mx-auto max-w-3xl px-6 pt-28 pb-16 sm:pt-32 sm:pb-20">
        <Link to="/plugins" className="text-sm text-muted transition-colors hover:text-text">
          ← All plugins
        </Link>
        {plugin === null ? (
          <p className="mt-10 text-lg text-muted">
            The plugin registry is unreachable right now. Try again in a few minutes.
          </p>
        ) : plugin === "missing" ? (
          <p className="mt-10 text-lg text-muted">
            This plugin isn’t in the registry — it may have been delisted, or the link is stale.
          </p>
        ) : (
          <PluginDetailBody plugin={plugin} />
        )}
      </main>
    </div>
  )
}

function PluginDetailBody({ plugin }: { plugin: PluginDetail }) {
  return (
    <article className="mt-10">
      <div className="flex items-start justify-between gap-6">
        <div className="flex min-w-0 items-center gap-5">
          <PluginAvatar avatarUrl={plugin.ownerAvatarUrl} sizeClass="size-16" />
          <div className="min-w-0">
            <h1 className="flex items-center gap-2 text-3xl font-semibold tracking-tight text-text">
              <span className="truncate">{plugin.name}</span>
              {plugin.verified === true && (
                <span className="rounded-full border border-hairline px-2 py-0.5 text-[11px] font-normal text-muted">
                  Verified
                </span>
              )}
            </h1>
            <p className="mt-1 text-[15px] text-muted">by {plugin.repo.split("/")[0]}</p>
          </div>
        </div>
        <div className="pt-2">
          <InstallButton repo={plugin.repo} prominent />
        </div>
      </div>

      {plugin.description !== undefined && plugin.description.length > 0 && (
        <p className="mt-8 max-w-2xl text-lg leading-relaxed text-muted">{plugin.description}</p>
      )}

      {plugin.tools.length > 0 && (
        <DetailSection title="Agent tools" count={plugin.tools.length}>
          <ul className="divide-y divide-hairline">
            {plugin.tools.map((tool) => (
              <li key={tool.name} className="py-3">
                <p className="font-mono text-[13px] text-text">{tool.name}</p>
                <p className="mt-0.5 text-sm text-muted">{tool.description}</p>
              </li>
            ))}
          </ul>
        </DetailSection>
      )}

      <DetailSection title="Information">
        <dl className="grid grid-cols-[8rem_1fr] gap-y-3 text-[15px]">
          <dt className="text-muted">Developer</dt>
          <dd className="text-text">{plugin.repo.split("/")[0]}</dd>
          {plugin.panes.length > 0 && (
            <>
              <dt className="text-muted">Panes</dt>
              <dd className="text-text">{plugin.panes.map((pane) => pane.title).join(", ")}</dd>
            </>
          )}
          <dt className="text-muted">Version</dt>
          <dd className="font-mono text-[13px] text-text">{plugin.version}</dd>
          <dt className="text-muted">Stars</dt>
          <dd className="text-text">{plugin.stars}</dd>
          <dt className="text-muted">Updated</dt>
          <dd className="text-text">{formatDate(plugin.pushedAt)}</dd>
          <dt className="text-muted">GitHub</dt>
          <dd>
            <a
              href={`https://github.com/${plugin.repo}`}
              rel="noopener"
              className="text-text underline decoration-hairline underline-offset-4 transition-colors hover:decoration-current"
            >
              {plugin.repo}
            </a>
          </dd>
        </dl>
      </DetailSection>

      <DetailSection title="Install">
        <div className="max-w-md">
          <CopyInstallCommand repo={plugin.repo} />
        </div>
      </DetailSection>
    </article>
  )
}

function DetailSection({
  title,
  count,
  children
}: {
  title: string
  count?: number
  children: ReactNode
}) {
  return (
    <section className="mt-12 border-t border-hairline pt-8">
      <h2 className="flex items-baseline gap-2 text-lg font-semibold text-text">
        {title}
        {count !== undefined && <span className="text-sm font-normal text-muted">{count}</span>}
      </h2>
      <div className="mt-4">{children}</div>
    </section>
  )
}

const formatDate = (iso: string): string => {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return iso
  return date.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" })
}
