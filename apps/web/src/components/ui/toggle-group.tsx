import { Toggle as BaseToggle } from "@base-ui/react/toggle"
import { ToggleGroup as BaseToggleGroup } from "@base-ui/react/toggle-group"
import type { ComponentPropsWithRef } from "react"

import { cn } from "../../lib/cn"

// Segmented control: the group is the track (secondary surface), the pressed
// item pops as a raised button — the macOS segmented-control read.
function ToggleGroup({ className, ...props }: ComponentPropsWithRef<typeof BaseToggleGroup>) {
  return (
    <BaseToggleGroup
      data-slot="toggle-group"
      className={cn("bg-secondary inline-flex items-center gap-0.5 rounded-md p-0.5", className)}
      {...props}
    />
  )
}

function ToggleGroupItem({ className, ...props }: ComponentPropsWithRef<typeof BaseToggle>) {
  return (
    <BaseToggle
      data-slot="toggle-group-item"
      className={cn(
        "text-muted-foreground flex-1 cursor-default rounded-[5px] px-2.5 py-1 text-xs font-medium whitespace-nowrap transition-colors outline-none",
        "focus-visible:ring-ring/50 focus-visible:ring-2",
        "data-[pressed]:bg-background data-[pressed]:text-foreground data-[pressed]:shadow-sm",
        className
      )}
      {...props}
    />
  )
}

export { ToggleGroup, ToggleGroupItem }
