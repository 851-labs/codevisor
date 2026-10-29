import { createFileRoute } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"

import { DOWNLOAD_SECTION_URL } from "../components/header-kit"
import { PlainPage, plainLinkClass } from "../components/plain-page"
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
    <PlainPage>
      <PluginLinkContent plugin={plugin} />
    </PlainPage>
  )
}

function PluginLinkContent({ plugin }: { plugin: PluginLookup }) {
  if (plugin === null)
    return <p>The plugin catalog is unreachable right now. Try again in a few minutes.</p>
  if (plugin === "missing")
    return (
      <>
        <p>This plugin isn’t in the catalog. It may have been removed, or the link is stale.</p>
        <ReportLine href={`mailto:${reportAddress}`} />
      </>
    )
  return <PluginLinks plugin={plugin} />
}

function PluginLinks({ plugin }: { plugin: CatalogPlugin }) {
  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight text-text">{plugin.title}</h1>
      <p className="flex flex-wrap gap-x-6 gap-y-2">
        <a href={`${appLinkOrigin}${pluginPath(plugin.name)}`} className={plainLinkClass}>
          Open in Codevisor
        </a>
        <a href={DOWNLOAD_SECTION_URL} className={plainLinkClass}>
          Get Codevisor
        </a>
      </p>
      <ReportLine href={reportHref(plugin)} />
    </>
  )
}

function ReportLine({ href }: { href: string }) {
  return (
    <p>
      Report a plugin:{" "}
      <a href={href} className={plainLinkClass}>
        {reportAddress}
      </a>
    </p>
  )
}
