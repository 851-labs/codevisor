import { createFileRoute, Link } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"

import { PluginAvatar } from "../components/plugin-directory"
import { SiteNav } from "../components/site-nav"
import { fetchCatalog, type CatalogPlugin, type CatalogSource } from "../lib/plugin-catalog"

interface DirectoryData {
  readonly plugins: ReadonlyArray<CatalogPlugin> | null
}

const fetchDirectory = createServerFn({ method: "GET" }).handler(
  async (): Promise<DirectoryData> => ({ plugins: await fetchCatalog() })
)

const sections: ReadonlyArray<{ readonly source: CatalogSource; readonly title: string }> = [
  { source: "first-party", title: "By Codevisor" },
  { source: "popular", title: "Popular" }
]

export const Route = createFileRoute("/plugins")({
  loader: () => fetchDirectory(),
  head: () => ({
    meta: [
      { title: "Plugins — Codevisor" },
      {
        name: "description",
        content:
          "Browse the plugins available in Codevisor: MCP servers that add tools, events, and inline UI for your agents."
      }
    ]
  }),
  component: PluginsDirectory
})

function PluginsDirectory() {
  const { plugins } = Route.useLoaderData()
  return (
    <div className="marketing-shell min-h-screen">
      <SiteNav />

      <main className="mx-auto max-w-5xl px-6 pt-28 pb-16 sm:pt-32 sm:pb-24">
        <h1 className="text-4xl font-semibold tracking-[-0.035em] text-text">Plugin directory</h1>
        <p className="mt-4 max-w-2xl text-lg text-muted">
          Every plugin here is available in Codevisor from Settings › Plugins › Browse Plugins.
        </p>

        {directoryContent(plugins)}
      </main>
    </div>
  )
}

function directoryContent(plugins: ReadonlyArray<CatalogPlugin> | null) {
  if (plugins === null)
    return (
      <p className="pt-12 text-lg text-muted">
        The plugin catalog is unreachable right now. Try again in a few minutes.
      </p>
    )
  if (plugins.length === 0)
    return <p className="pt-12 text-lg text-muted">No plugins are available right now.</p>
  return sections.map((section) => (
    <DirectorySection
      key={section.source}
      title={section.title}
      plugins={plugins.filter((plugin) => plugin.source === section.source)}
    />
  ))
}

function DirectorySection({
  title,
  plugins
}: {
  title: string
  plugins: ReadonlyArray<CatalogPlugin>
}) {
  if (plugins.length === 0) return null
  return (
    <section className="pt-12">
      <h2 className="text-lg font-semibold text-text">{title}</h2>
      <ul className="mt-6 grid grid-cols-1 gap-x-10 gap-y-8 sm:grid-cols-2">
        {plugins.map((plugin) => (
          <PluginRow key={plugin.name} plugin={plugin} />
        ))}
      </ul>
    </section>
  )
}

function PluginRow({ plugin }: { plugin: CatalogPlugin }) {
  return (
    <li className="flex items-center gap-4 rounded-xl border border-hairline bg-white/[0.03] p-4 transition-colors hover:bg-white/[0.05]">
      <Link
        to="/plugins/$pluginId"
        params={{ pluginId: plugin.name }}
        className="group flex min-w-0 flex-1 items-center gap-4"
      >
        <PluginAvatar avatarUrl={plugin.iconUrl} sizeClass="size-12" />
        <span className="min-w-0">
          <span className="block truncate text-[16px] font-semibold text-text transition-colors group-hover:text-white">
            {plugin.title}
          </span>
          <span className="block truncate text-[15px] text-muted">
            {plugin.description.length > 0 ? plugin.description : plugin.publisher}
          </span>
        </span>
      </Link>
    </li>
  )
}
