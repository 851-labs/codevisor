import { createFileRoute, Link } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"

import { DetailSection, PluginCapabilityList } from "../components/plugin-capabilities"
import { PluginAvatar } from "../components/plugin-directory"
import { SiteNav } from "../components/site-nav"
import { fetchCatalog, reportHref, type CatalogPlugin } from "../lib/plugin-catalog"

type PluginLookup = CatalogPlugin | "missing" | null

interface PluginDetailData {
  readonly plugin: PluginLookup
}

const fetchPlugin = createServerFn({ method: "GET" })
  .validator((name: string) => name)
  .handler(async ({ data: name }): Promise<PluginDetailData> => {
    const plugins = await fetchCatalog()
    if (plugins === null) return { plugin: null }
    return { plugin: plugins.find((plugin) => plugin.name === name) ?? "missing" }
  })

export const Route = createFileRoute("/plugins_/$pluginId")({
  loader: ({ params }) => fetchPlugin({ data: params.pluginId }),
  head: (ctx) => ({ meta: pluginMeta(ctx.loaderData?.plugin ?? null) }),
  component: PluginDetailPage
})

const pluginMeta = (plugin: PluginLookup) => {
  if (plugin === null || plugin === "missing") return [{ title: "Plugin — Codevisor Plugins" }]
  return [
    { title: `${plugin.title} — Codevisor Plugins` },
    { name: "description", content: plugin.description }
  ]
}

function PluginDetailPage() {
  const { plugin } = Route.useLoaderData()
  return (
    <div className="marketing-shell min-h-screen">
      <SiteNav />
      <main className="mx-auto max-w-3xl px-6 pt-28 pb-16 sm:pt-32 sm:pb-20">
        <Link to="/plugins" className="text-sm text-muted transition-colors hover:text-text">
          ← All plugins
        </Link>
        {pluginDetailContent(plugin)}
      </main>
    </div>
  )
}

function pluginDetailContent(plugin: PluginLookup) {
  if (plugin === null)
    return (
      <p className="mt-10 text-lg text-muted">
        The plugin catalog is unreachable right now. Try again in a few minutes.
      </p>
    )
  if (plugin === "missing")
    return (
      <p className="mt-10 text-lg text-muted">
        This plugin isn’t in the catalog. It may have been removed, or the link is stale.
      </p>
    )
  return <PluginDetailBody plugin={plugin} />
}

function PluginDetailBody({ plugin }: { plugin: CatalogPlugin }) {
  return (
    <article className="mt-10">
      <PluginHeader plugin={plugin} />

      {plugin.description.length > 0 && (
        <p className="mt-8 max-w-2xl text-lg leading-relaxed text-muted">{plugin.description}</p>
      )}

      <DetailSection title="Capabilities">
        <PluginCapabilityList capabilities={plugin.capabilities} remoteUrl={plugin.remoteUrl} />
      </DetailSection>

      <DetailSection title="Information">
        <PluginInformation plugin={plugin} />
      </DetailSection>

      <DetailSection title="Install">
        <p className="text-[15px] text-muted">
          In Codevisor, open Settings › Plugins › Browse Plugins and choose {plugin.title}.
        </p>
      </DetailSection>
    </article>
  )
}

function PluginHeader({ plugin }: { plugin: CatalogPlugin }) {
  return (
    <div className="flex items-start justify-between gap-6">
      <div className="flex min-w-0 items-center gap-5">
        <PluginAvatar avatarUrl={plugin.iconUrl} sizeClass="size-16" />
        <div className="min-w-0">
          <h1 className="truncate text-3xl font-semibold tracking-tight text-text">
            {plugin.title}
          </h1>
          <p className="mt-1 text-[15px] text-muted">by {plugin.publisher}</p>
        </div>
      </div>
      <a
        href={reportHref(plugin)}
        className="shrink-0 pt-2 text-sm text-muted underline decoration-hairline underline-offset-4 transition-colors hover:text-text"
      >
        Report
      </a>
    </div>
  )
}

function PluginInformation({ plugin }: { plugin: CatalogPlugin }) {
  return (
    <dl className="grid grid-cols-[8rem_1fr] gap-y-3 text-[15px]">
      <dt className="text-muted">Publisher</dt>
      <dd className="text-text">{plugin.publisher}</dd>
      <dt className="text-muted">Version</dt>
      <dd className="font-mono text-[13px] text-text">{plugin.version}</dd>
      {plugin.ageRating !== undefined && (
        <>
          <dt className="text-muted">Age rating</dt>
          <dd className="text-text">{plugin.ageRating}+</dd>
        </>
      )}
      <dt className="text-muted">Registry name</dt>
      <dd className="font-mono text-[13px] text-text">{plugin.name}</dd>
      {plugin.websiteUrl !== undefined && (
        <>
          <dt className="text-muted">Website</dt>
          <dd>
            <a
              href={plugin.websiteUrl}
              rel="noopener"
              className="text-text underline decoration-hairline underline-offset-4 transition-colors hover:decoration-current"
            >
              {new URL(plugin.websiteUrl).host}
            </a>
          </dd>
        </>
      )}
    </dl>
  )
}
