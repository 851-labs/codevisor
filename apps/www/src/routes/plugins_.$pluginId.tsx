import { createFileRoute } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"

import { DOWNLOAD_SECTION_URL } from "../components/header-kit"
import { ReportLine } from "../components/report-line"
import { HeroButton, PageHero, SitePage } from "../components/site-page"
import { reportAddress, reportHref, type CatalogPlugin } from "../lib/plugin-catalog"
import { loadPlugin, pluginPath, type PluginLookup } from "../lib/plugin-index"

interface PluginLinkData {
  readonly plugin: PluginLookup
}

const fetchPlugin = createServerFn({ method: "GET" })
  .validator((name: string) => name)
  .handler(async ({ data: name }): Promise<PluginLinkData> => ({ plugin: await loadPlugin(name) }))

export const Route = createFileRoute("/plugins_/$pluginId")({
  loader: ({ params }) => fetchPlugin({ data: params.pluginId }),
  head: (ctx) => ({ meta: [{ title: pluginTitle(ctx.loaderData?.plugin ?? null) }] }),
  component: PluginLinkPage
})

const appLinkOrigin = "https://codevisor.dev"

const pluginTitle = (plugin: PluginLookup): string => {
  if (plugin === null || plugin === "missing") return "Plugin — Codevisor"
  return `${plugin.title} — Codevisor`
}

function PluginLinkPage() {
  const { plugin } = Route.useLoaderData()
  return (
    <SitePage>
      <PluginLinkContent plugin={plugin} />
    </SitePage>
  )
}

function PluginLinkContent({ plugin }: { plugin: PluginLookup }) {
  if (plugin === null)
    return (
      <PageHero description="The plugin catalog is unreachable right now. Try again in a few minutes." />
    )
  if (plugin === "missing")
    return (
      <PageHero description="This plugin isn’t in the catalog. It may have been removed, or the link is stale.">
        <ReportLine href={`mailto:${reportAddress}`} />
      </PageHero>
    )
  return <PluginLinks plugin={plugin} />
}

function PluginLinks({ plugin }: { plugin: CatalogPlugin }) {
  return (
    <PageHero title={plugin.title}>
      <div className="mt-9 flex flex-wrap items-center justify-center gap-x-6 gap-y-4">
        <HeroButton href={`${appLinkOrigin}${pluginPath(plugin.name)}`}>
          Open in Codevisor
        </HeroButton>
        <a
          href={DOWNLOAD_SECTION_URL}
          className="text-[16px] font-semibold text-muted transition-colors hover:text-text"
        >
          Get Codevisor
        </a>
      </div>
      <ReportLine href={reportHref(plugin)} />
    </PageHero>
  )
}
