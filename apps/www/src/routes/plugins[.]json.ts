import { createFileRoute } from "@tanstack/react-router"

import { reportAddress, type CatalogPlugin } from "../lib/plugin-catalog"
import { fetchCatalog, pluginPath } from "../lib/plugin-index"

export const Route = createFileRoute("/plugins.json")({
  server: {
    handlers: {
      GET: async ({ request }) => pluginIndexResponse(new URL(request.url).origin)
    }
  }
})

const indexCacheControl = "public, max-age=300"

const pluginIndexResponse = async (origin: string): Promise<Response> => {
  const plugins = await fetchCatalog()
  if (plugins === null) return unavailable()

  return Response.json(
    { plugins: plugins.map((plugin) => indexEntry(plugin, origin)), report: reportAddress },
    { headers: { "cache-control": indexCacheControl, "access-control-allow-origin": "*" } }
  )
}

const indexEntry = (plugin: CatalogPlugin, origin: string) => ({
  id: plugin.name,
  name: plugin.title,
  publisher: plugin.publisher,
  description: plugin.description,
  ageRating: plugin.ageRating ?? null,
  iconUrl: plugin.iconUrl ?? null,
  url: new URL(pluginPath(plugin.name), origin).toString()
})

const unavailable = (): Response =>
  Response.json(
    { error: "The plugin catalog is unreachable right now. Try again in a few minutes." },
    { status: 503, headers: { "cache-control": "no-store", "retry-after": "60" } }
  )
