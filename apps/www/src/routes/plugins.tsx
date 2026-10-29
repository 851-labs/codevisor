import { createFileRoute } from "@tanstack/react-router"

import { ReportLine } from "../components/report-line"
import { PageHero, plainLinkClass, SitePage } from "../components/site-page"
import { reportAddress } from "../lib/plugin-catalog"
import { pluginIndexPath } from "../lib/plugin-index"

export const Route = createFileRoute("/plugins")({
  head: () => ({
    meta: [
      { title: "Plugin index — Codevisor" },
      { name: "description", content: "The index of every plugin available in Codevisor." }
    ]
  }),
  component: PluginIndexPage
})

function PluginIndexPage() {
  return (
    <SitePage>
      <PageHero
        title="Plugin index"
        description={
          <>
            Every plugin available in Codevisor is listed with its universal link in{" "}
            <a href={pluginIndexPath} className={plainLinkClass}>
              {pluginIndexPath}
            </a>
            .
          </>
        }
      >
        <ReportLine href={`mailto:${reportAddress}`} />
      </PageHero>
    </SitePage>
  )
}
