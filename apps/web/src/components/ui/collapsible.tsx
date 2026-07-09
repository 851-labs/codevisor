import { Collapsible as BaseCollapsible } from "@base-ui/react/collapsible"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

const Collapsible = BaseCollapsible.Root
const CollapsibleTrigger = BaseCollapsible.Trigger

function CollapsiblePanel({
  className,
  ...props
}: ComponentPropsWithRef<typeof BaseCollapsible.Panel>) {
  return (
    <BaseCollapsible.Panel
      data-slot="collapsible-panel"
      className={cn(
        "h-[var(--collapsible-panel-height)] overflow-hidden transition-[height] duration-150",
        "data-[starting-style]:h-0 data-[ending-style]:h-0",
        className
      )}
      {...props}
    />
  )
}

export { Collapsible, CollapsibleTrigger, CollapsiblePanel }
