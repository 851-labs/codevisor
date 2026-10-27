import type { PluginCapabilities } from "@codevisor/api"
import type { ReactNode } from "react"

interface CapabilityItem {
  readonly key: string
  readonly label: string
  readonly description: string | undefined
}

export function PluginCapabilityList({
  capabilities,
  remoteUrl
}: {
  capabilities: PluginCapabilities | undefined
  remoteUrl: string | undefined
}) {
  if (capabilities === undefined) return <UndeclaredCapabilities remoteUrl={remoteUrl} />
  return (
    <div className="space-y-8">
      <CapabilityGroup title="Agent tools" items={capabilities.tools.map(toolItem)} />
      <CapabilityGroup title="Events" items={capabilities.events.map(namedItem)} />
      <CapabilityGroup title="Skills" items={capabilities.skills.map(namedItem)} />
      <CapabilityGroup title="Panes" items={capabilities.panes.map(paneItem)} />
      <CapabilityGroup title="Webhooks" items={capabilities.ingress.map(ingressItem)} />
    </div>
  )
}

export function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-12 border-t border-hairline pt-8">
      <h2 className="text-lg font-semibold text-text">{title}</h2>
      <div className="mt-4">{children}</div>
    </section>
  )
}

function UndeclaredCapabilities({ remoteUrl }: { remoteUrl: string | undefined }) {
  return (
    <p className="text-[15px] text-muted">
      A hosted MCP server{remoteUrl === undefined ? "" : ` at ${remoteUrl}`}. Codevisor lists its
      tools after you connect it.
    </p>
  )
}

function CapabilityGroup({
  title,
  items
}: {
  title: string
  items: ReadonlyArray<CapabilityItem>
}) {
  if (items.length === 0) return null
  return (
    <div>
      <h3 className="flex items-baseline gap-2 text-[15px] font-semibold text-text">
        {title}
        <span className="text-sm font-normal text-muted">{items.length}</span>
      </h3>
      <ul className="mt-2 divide-y divide-hairline">
        {items.map((item) => (
          <li key={item.key} className="py-3">
            <p className="font-mono text-[13px] text-text">{item.label}</p>
            {item.description !== undefined && (
              <p className="mt-0.5 text-sm text-muted">{item.description}</p>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}

const toolItem = (tool: PluginCapabilities["tools"][number]): CapabilityItem => ({
  key: tool.name,
  label: tool.app === true ? `${tool.name} · inline UI` : tool.name,
  description: tool.description
})

const namedItem = (item: { name: string; description?: string }): CapabilityItem => ({
  key: item.name,
  label: item.name,
  description: item.description
})

const paneItem = (pane: PluginCapabilities["panes"][number]): CapabilityItem => ({
  key: pane.type,
  label: pane.title,
  description: undefined
})

const ingressItem = (ingress: PluginCapabilities["ingress"][number]): CapabilityItem => ({
  key: ingress.name,
  label: ingress.title ?? ingress.name,
  description: undefined
})
