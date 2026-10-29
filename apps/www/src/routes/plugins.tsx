import { createFileRoute } from "@tanstack/react-router"

import { PlainPage, plainLinkClass } from "../components/plain-page"
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
    <PlainPage>
      <h1 className="text-2xl font-semibold tracking-tight text-text">Plugin index</h1>
      <p>
        Every plugin available in Codevisor is listed with its universal link in{" "}
        <a href={pluginIndexPath} className={plainLinkClass}>
          {pluginIndexPath}
        </a>
        .
      </p>
      <p>
        Report a plugin:{" "}
        <a href={`mailto:${reportAddress}`} className={plainLinkClass}>
          {reportAddress}
        </a>
      </p>
    </PlainPage>
  )
}
