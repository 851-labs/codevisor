import { Popover as BasePopover } from "@base-ui/react/popover"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"
import { popupSurfaceClassName } from "./menu"

const Popover = BasePopover.Root
const PopoverTrigger = BasePopover.Trigger
const PopoverClose = BasePopover.Close

function PopoverContent({
  className,
  sideOffset = 6,
  align = "center",
  side,
  children,
  ...props
}: ComponentPropsWithRef<typeof BasePopover.Popup> & {
  sideOffset?: number
  align?: ComponentPropsWithRef<typeof BasePopover.Positioner>["align"]
  side?: ComponentPropsWithRef<typeof BasePopover.Positioner>["side"]
}) {
  return (
    <BasePopover.Portal>
      <BasePopover.Positioner align={align} side={side} sideOffset={sideOffset} className="z-50">
        <BasePopover.Popup
          data-slot="popover-content"
          className={cn(popupSurfaceClassName, "w-72 p-3", className)}
          {...props}
        >
          {children}
        </BasePopover.Popup>
      </BasePopover.Positioner>
    </BasePopover.Portal>
  )
}

export { Popover, PopoverTrigger, PopoverContent, PopoverClose }
