import { Suspense, type ReactNode } from "react"
import { createFileRoute, notFound, redirect } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import { useFumadocsLoader } from "fumadocs-core/source/client"
import { DocsLayout } from "fumadocs-ui/layouts/docs"
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from "fumadocs-ui/layouts/docs/page"
import browserCollections from "../../../.source/browser"

import { OpenAPIPage } from "../../components/api-page"
import { useMDXComponents } from "../../components/mdx"
import { baseOptions } from "../../lib/layout.shared"
import { source } from "../../lib/source"

const movedDocsRedirects: Record<string, string> = {
  "getting-started": "/docs",
  app: "/docs",
  "extensions/plugins": "/docs/plugins",
  "extensions/mcp": "/docs/mcp",
  "extensions/skills": "/docs/skills",
  "extensions/custom-agents": "/docs/custom-agents",
  "server/quickstart": "/docs/quickstart",
  "server/installation": "/docs/installation",
  "server/configuration": "/docs/configuration",
  "server/authentication": "/docs/authentication",
  "server/security": "/docs/security",
  "server/api-concepts": "/docs/api-concepts",
  "server/realtime": "/docs/realtime",
  "server/terminals": "/docs/terminals",
  "server/operations": "/docs/operations"
}

export const Route = createFileRoute("/docs/$")({
  component: Page,
  loader: async ({ params }) => {
    const slugs = params._splat?.split("/").filter(Boolean) ?? []
    const redirectHref = movedDocsRedirects[slugs.join("/")]
    if (redirectHref) throw redirect({ href: redirectHref, statusCode: 301 })

    const data = await serverLoader({ data: slugs })
    if (data.type === "docs") await clientLoader.preload(data.path)
    return data
  },
  head: ({ loaderData }) => ({
    meta: [
      { title: `${loaderData?.title ?? "Docs"} — Codevisor` },
      {
        name: "description",
        content:
          loaderData?.description ??
          "Documentation for the Codevisor app, extensions, server, and API."
      }
    ]
  })
})

const serverLoader = createServerFn({ method: "GET" })
  .validator((slugs: string[]) => slugs)
  .handler(async ({ data: slugs }) => {
    const resolvedSource = await source.get()
    const page = resolvedSource.getPage(slugs)
    if (!page) throw notFound()

    const pageTree = await resolvedSource.serializePageTree(resolvedSource.getPageTree())
    if (page.type === "openapi") {
      return {
        type: "openapi" as const,
        title: page.data.title,
        description: page.data.description,
        pageTree,
        props: page.data.getOpenAPIPageProps()
      }
    }
    return {
      type: "docs" as const,
      title: page.data.title,
      description: page.data.description,
      path: page.path,
      pageTree
    }
  })

const clientLoader = browserCollections.docs.createClientLoader({
  component({ toc, frontmatter, default: MDX }, _props: { path: string }) {
    return (
      <DocsPage toc={toc}>
        <DocsTitle>{frontmatter.title}</DocsTitle>
        <DocsDescription>{frontmatter.description}</DocsDescription>
        <DocsBody>
          <MDX components={useMDXComponents()} />
        </DocsBody>
      </DocsPage>
    )
  }
})

function Page() {
  const page = useFumadocsLoader(Route.useLoaderData())
  let content: ReactNode

  if (page.type === "openapi") {
    content = (
      <DocsPage full>
        <DocsTitle>{page.title}</DocsTitle>
        <DocsDescription>{page.description}</DocsDescription>
        <DocsBody>
          <OpenAPIPage {...page.props} />
        </DocsBody>
      </DocsPage>
    )
  } else {
    content = <Suspense>{clientLoader.useContent(page.path, { path: page.path })}</Suspense>
  }

  return (
    <DocsLayout {...baseOptions()} tree={page.pageTree}>
      {content}
    </DocsLayout>
  )
}
