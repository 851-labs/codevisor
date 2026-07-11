import { dynamicLoader } from "fumadocs-core/source/dynamic"
import { lucideIconsPlugin } from "fumadocs-core/source/lucide-icons"
import { docs } from "../../.source/server"
import { openapi } from "./openapi"

export const source = dynamicLoader(
  {
    docs: docs.toFumadocsSource(),
    openapi: openapi.dynamicSource({
      baseDir: "api-reference",
      groupBy: "tag",
      meta: { folderStyle: "separator" }
    })
  },
  {
    baseUrl: "/docs",
    plugins: [lucideIconsPlugin(), openapi.loaderPlugin()]
  }
)
