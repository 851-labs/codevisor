import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

const TooltipProvider = BaseTooltip.Provider
const Tooltip = BaseTooltip.Root
const TooltipTrigger = BaseTooltip.Trigger

function TooltipContent({
  className,
  sideOffset = 6,
  side = "top",
  children,
  ...props
}: ComponentPropsWithRef<typeof BaseTooltip.Popup> & {
  sideOffset?: number
  side?: ComponentPropsWithRef<typeof BaseTooltip.Positioner>["side"]
}) {
  return (
    <BaseTooltip.Portal>
      <BaseTooltip.Positioner side={side} sideOffset={sideOffset} className="z-50">
        <BaseTooltip.Popup
          data-slot="tooltip-content"
          className={cn(
            "rounded-md border px-2 py-1 text-xs",
            "bg-[var(--herdman-popover-bg)] text-[var(--herdman-popover-fg)]",
            "border-[var(--herdman-popover-border)] shadow-[var(--herdman-popover-shadow)]",
            "transition-opacity duration-100",
            "data-[starting-style]:opacity-0 data-[ending-style]:opacity-0",
            className
          )}
          {...props}
        >
          {children}
        </BaseTooltip.Popup>
      </BaseTooltip.Positioner>
    </BaseTooltip.Portal>
  )
}

export { TooltipProvider, Tooltip, TooltipTrigger, TooltipContent }
